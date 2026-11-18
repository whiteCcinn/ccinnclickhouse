import Foundation

/// Every function a statement calls or names, the way the server resolves it:
/// - `name(` anywhere (any clause, any depth), except after the few keywords that open a parenthesis without a call,
///   a type name after `AS` / `::`, and an alias's column list (`AS t (a, b)`); a call right after a call's `)` is
///   the same function, parametric (`quantile(0.5)(x)`);
/// - the name after APPLY, with or without parentheses, quoted or not, in every chained transformer;
/// - the bare first argument of a higher-order function called with two or more arguments (26.8: `arrayMap(f, …)`);
/// - the aggregate named by the string of arrayReduce, arrayReduceInRanges and initializeAggregation.
/// One pass with a bracket stack: linear in the statement.
struct FunctionReferences {
    enum Kind: Equatable, Sendable {
        case call
        case transformer
        case higherOrderArgument
        case aggregateName
    }

    struct Reference: Equatable, Sendable {
        let name: String
        let kind: Kind
    }

    /// Every reference, in order.
    private(set) var references: [Reference] = []
    /// A construct that names a function in a way that cannot be read (APPLY of an expression, a higher-order function's
    /// first argument that is neither a lambda nor a name): refused for both audiences.
    private(set) var unresolvable: String?
    /// Constructs only AI access refuses: a parenthesised expression called like a function, a non-literal aggregate name.
    private(set) var aiUnresolvable: String?

    /// Words that open a parenthesis without calling a function there (`IN (…)`, `OVER (…)`, `USING (…)` …).
    static let syntacticKeywords: Set<String> = [
        "SELECT", "FROM", "JOIN", "WHERE", "PREWHERE", "HAVING", "QUALIFY", "ON", "USING", "IN", "EXISTS", "VALUES", "OVER", "AND", "OR", "NOT",
        "BY", "WHEN", "THEN", "ELSE", "CASE", "DISTINCT", "ALL", "ANY", "EXCEPT", "INTERSECT", "UNION", "WITH", "LIMIT", "OFFSET", "INTERVAL",
        "LIKE", "ILIKE", "BETWEEN", "IS", "WINDOW", "PARTITION", "FILTER", "TOP", "DESCRIBE", "DESC", "GLOBAL", "SETS", "ROLLUP", "CUBE",
        "INTERPOLATE", "TO", "STEP", "COLUMNS", "REPLACE", "APPLY", "SAMPLE", "FINAL", "RECURSIVE", "EXPLAIN", "TABLE", "AS",
    ]
    /// Functions whose first argument names an aggregate function as a string.
    static let stringNamedAggregateFunctions: Set<String> = ["arrayreduce", "arrayreduceinranges", "initializeaggregation"]

    init(_ words: StatementWords) {
        let tokens = words.tokens
        let count = tokens.count
        // Bracket structure in one pass: the closing index of every opening bracket, and for `(` its first top-level comma
        // and whether a top-level `->` comes before it (a lambda first argument) or anywhere (a lambda inside APPLY).
        var closing = [Int?](repeating: nil, count: count)
        var opening = [Int?](repeating: nil, count: count)
        var firstComma = [Int?](repeating: nil, count: count)
        var arrowBeforeComma = [Bool](repeating: false, count: count)
        var hasArrow = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for index in tokens.indices {
            let token = tokens[index]
            let text = words.words[index]
            if token.kind == .punctuation, ["(", "[", "{"].contains(text) {
                stack.append(index)
            } else if token.kind == .punctuation, [")", "]", "}"].contains(text) {
                if let open = stack.popLast() {
                    closing[open] = index
                    opening[index] = open
                }
            } else if let open = stack.last {
                if token.kind == .punctuation, text == ",", firstComma[open] == nil { firstComma[open] = index }
                if token.kind == .operator, text == "->" {
                    hasArrow[open] = true
                    if firstComma[open] == nil { arrowBeforeComma[open] = true }
                }
            }
        }
        func isName(_ index: Int) -> Bool { words.isName(index) }
        func isWord(_ index: Int) -> Bool { words.isWord(index) }
        func name(_ index: Int) -> String {
            tokens[index].kind == .quotedIdentifier ? words.lexer.identifierValue(of: tokens[index]) : words.lexer.text(of: tokens[index])
        }
        func isNumber(_ range: Range<Int>) -> Bool {
            if range.count == 1 { return tokens[range.lowerBound].kind == .number }
            return range.count == 2 && tokens[range.lowerBound].kind == .operator && ["-", "+"].contains(words.words[range.lowerBound])
                && tokens[range.lowerBound + 1].kind == .number
        }

        /// The first argument of a higher-order or string-named function.
        func arguments(of function: String, open: Int) {
            let lower = function.lowercased()
            let end = firstComma[open] ?? closing[open] ?? count
            let first = (open + 1)..<max(open + 1, end)
            if AIFunctionCatalog.higherOrder.contains(lower), firstComma[open] != nil, !arrowBeforeComma[open] {
                if first.count == 1, isName(first.lowerBound) {
                    references.append(Reference(name: name(first.lowerBound), kind: .higherOrderArgument))
                } else if !isNumber(first) {
                    unresolvable = unresolvable
                        ?? "The first argument of `\(function)()` is neither a lambda nor a function name, so the function it calls cannot be checked."
                }
            }
            if Self.stringNamedAggregateFunctions.contains(lower) {
                if first.count == 1, tokens[first.lowerBound].kind == .string {
                    let value = words.lexer.stringValue(of: tokens[first.lowerBound])
                    let aggregate = String(value.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
                    references.append(Reference(name: aggregate, kind: .aggregateName))
                } else {
                    aiUnresolvable = aiUnresolvable ?? "`\(function)()` names its aggregate function with an expression; AI access needs a string literal."
                }
            }
        }

        /// `APPLY f`, `APPLY(f)`, `` APPLY(`f`) ``, `APPLY(f(params))`, `APPLY(x -> …)`.
        func applyTransformer(at index: Int) {
            let next = index + 1
            let refused = "APPLY must name a function or take a lambda, so the function it calls can be checked."
            if words.isPunctuation(next, "(") {
                let close = closing[next] ?? count
                let inner = (next + 1)..<max(next + 1, close)
                if hasArrow[next] { return } // a lambda: its calls are seen as calls
                if inner.count == 1, isName(inner.lowerBound) {
                    references.append(Reference(name: name(inner.lowerBound), kind: .transformer))
                } else if inner.count >= 3, isName(inner.lowerBound), words.isPunctuation(inner.lowerBound + 1, "("),
                          closing[inner.lowerBound + 1] == close - 1 {
                    return // `APPLY(quantile(0.9))`: seen as a call
                } else {
                    unresolvable = unresolvable ?? refused
                }
            } else if isName(next) {
                references.append(Reference(name: name(next), kind: .transformer))
            } else {
                unresolvable = unresolvable ?? refused
            }
        }

        var calls = Set<Int>()       // `(` that opens a call
        var types = Set<Int>()       // `(` that opens a type's parameters
        var open: [Int] = []         // enclosing `(` indices while scanning
        for index in tokens.indices {
            let text = words.words[index]
            let kind = tokens[index].kind
            if kind == .punctuation, [")", "]", "}"].contains(text) {
                _ = open.popLast()
                continue
            }
            // Every APPLY, also after a `.`: a word read as a transformer that is not one only over-refuses.
            if isWord(index), text == "APPLY" {
                applyTransformer(at: index)
            }
            guard kind == .punctuation, ["(", "[", "{"].contains(text) else { continue }
            defer { open.append(index) }
            guard text == "(" else { continue }
            let previous = index - 1
            if previous >= 0, isName(previous) {
                let value = name(previous)
                let afterAs = previous >= 1 && isWord(previous - 1) && words.words[previous - 1] == "AS"
                let afterCast = previous >= 1 && tokens[previous - 1].kind == .operator && words.words[previous - 1] == "::"
                let insideType = open.last.map(types.contains) ?? false
                if (afterAs || afterCast || insideType) && ReadOnlySQLGuard.isDataType(value) {
                    types.insert(index)
                    continue
                }
                if afterAs { continue } // an alias's column list: `AS t (a, b)`
                if isWord(previous), Self.syntacticKeywords.contains(words.words[previous]) { continue }
                calls.insert(index)
                references.append(Reference(name: value, kind: .call))
                arguments(of: value, open: index)
            } else if previous >= 0, words.isPunctuation(previous, ")") {
                // `f(params)(args)`: the same function, parametric. Anything else called like a function is not readable.
                if let start = opening[previous], calls.contains(start) {
                    calls.insert(index)
                } else {
                    aiUnresolvable = aiUnresolvable ?? "A parenthesised expression is called like a function; AI access calls only reviewed functions by name."
                }
            }
        }

    }
}
