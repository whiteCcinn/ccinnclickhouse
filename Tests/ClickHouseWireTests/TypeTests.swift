import Testing
@testable import ClickHouseWire

@Suite("ClickHouse type grammar")
struct TypeTests {
    @Test func simpleTypes() {
        #expect(ClickHouseType.parse("UInt64").kind == .integer)
        #expect(ClickHouseType.parse("Int256").kind == .integer)
        #expect(ClickHouseType.parse("Float32").kind == .float)
        #expect(ClickHouseType.parse("BFloat16").kind == .float)
        #expect(ClickHouseType.parse("Bool").kind == .boolean)
        #expect(ClickHouseType.parse("String").kind == .string)
        #expect(ClickHouseType.parse("FixedString(16)").kind == .string)
        #expect(ClickHouseType.parse("UUID").kind == .uuid)
        #expect(ClickHouseType.parse("IPv4").kind == .ipAddress)
        #expect(ClickHouseType.parse("Date32").kind == .date)
        #expect(ClickHouseType.parse("DateTime").kind == .dateTime)
        #expect(ClickHouseType.parse("Nothing").kind == .nothing)
        #expect(ClickHouseType.parse("IntervalDay").kind == .interval)
    }

    @Test func parameterisedTypes() {
        let decimal = ClickHouseType.parse("Decimal(18, 4)")
        #expect(decimal.kind == .decimal)
        #expect(decimal.name == "Decimal")
        #expect(decimal.arguments == [.number("18"), .number("4")])

        let dateTime = ClickHouseType.parse("DateTime64(3, 'Asia/Shanghai')")
        #expect(dateTime.kind == .dateTime)
        #expect(dateTime.timeZone == "Asia/Shanghai")
        #expect(ClickHouseType.parse("DateTime('Europe/Berlin')").timeZone == "Europe/Berlin")
        #expect(ClickHouseType.parse("DateTime").timeZone == nil)
    }

    @Test func wrappers() {
        let type = ClickHouseType.parse("LowCardinality(Nullable(String))")
        #expect(type.isNullable)
        #expect(type.kind == .string)
        #expect(type.unwrapped.name == "String")
        #expect(!type.isComposite)

        let nullableArrayElement = ClickHouseType.parse("Array(Nullable(Int32))")
        #expect(!nullableArrayElement.isNullable)
        #expect(nullableArrayElement.kind == .array)
        #expect(nullableArrayElement.isComposite)
        #expect(nullableArrayElement.elementType?.isNullable == true)
    }

    @Test func compositeTypes() {
        let tuple = ClickHouseType.parse("Tuple(a UInt8, b Array(String))")
        #expect(tuple.kind == .tuple)
        #expect(tuple.isComposite)
        #expect(tuple.arguments.count == 2)
        if case let .named(name, element) = tuple.arguments[1] {
            #expect(name == "b")
            #expect(element.kind == .array)
        } else {
            Issue.record("expected a named tuple element")
        }

        let map = ClickHouseType.parse("Map(LowCardinality(String), Array(Tuple(UInt8, String)))")
        #expect(map.kind == .map)
        #expect(map.isComposite)

        let nested = ClickHouseType.parse("Nested(x UInt32, y String)")
        #expect(nested.kind == .nested)
        #expect(nested.isComposite)
    }

    @Test func enumsAndAggregates() {
        let enumeration = ClickHouseType.parse("Enum8('a' = 1, 'b\\'c' = -2, 'd = e' = 3)")
        #expect(enumeration.kind == .enumeration)
        #expect(enumeration.arguments == [.enumEntry("a", 1), .enumEntry("b'c", -2), .enumEntry("d = e", 3)])

        let state = ClickHouseType.parse("AggregateFunction(quantiles(0.5, 0.9), Float64)")
        #expect(state.kind == .aggregateState)
        let simple = ClickHouseType.parse("SimpleAggregateFunction(sum, UInt64)")
        #expect(simple.kind == .integer)
        #expect(simple.isNumeric)
    }

    @Test func newerTypes() {
        #expect(ClickHouseType.parse("JSON(max_dynamic_paths = 10, a.b UInt32, SKIP a.c)").kind == .json)
        #expect(ClickHouseType.parse("Object('json')").kind == .json)
        #expect(ClickHouseType.parse("Variant(String, UInt64)").kind == .variant)
        #expect(ClickHouseType.parse("Dynamic(max_types = 8)").kind == .variant)
        #expect(ClickHouseType.parse("Time64(3)").kind == .time)
        #expect(ClickHouseType.parse("Point").kind == .geo)
        #expect(ClickHouseType.parse("MultiPolygon").kind == .geo)
    }

    @Test func numericAndTemporalFlags() {
        #expect(ClickHouseType.parse("Nullable(Decimal(38, 10))").isNumeric)
        #expect(ClickHouseType.parse("Nullable(DateTime64(6))").isTemporal)
        #expect(!ClickHouseType.parse("String").isNumeric)
        #expect(!ClickHouseType.parse("Bool").isNumeric)
    }

    @Test func descriptionRoundTrips() {
        let samples = [
            "UInt8", "Nullable(String)", "Array(Tuple(a UInt8, b String))", "Map(String, UInt64)",
            "DateTime64(3, 'UTC')", "Enum8('a' = 1, 'b' = 2)", "Decimal(10, 2)",
        ]
        for sample in samples {
            #expect(ClickHouseType.parse(sample).description == sample)
        }
    }

    @Test func malformedTypesNeverFail() {
        let inputs = ["", "(", ")", "Array(", "Array(UInt8", "Tuple(a, ,)", "'", "Enum8('a' = )", "Map(String",
                      String(repeating: "Array(", count: 500) + "UInt8" + String(repeating: ")", count: 500), "Decimal(99999999999999999999, 2)"]
        for input in inputs {
            let type = ClickHouseType.parse(input)
            #expect(type.raw == input.trimmingCharacters(in: .whitespaces))
        }
        let deep = ClickHouseType.parse(String(repeating: "Array(", count: 500) + "UInt8" + String(repeating: ")", count: 500))
        #expect(deep.kind == .other || deep.kind == .array)
    }

    @Test func fuzzNeverTraps() {
        var generator = SplitMix64(seed: 0xC11C)
        let alphabet = Array("ArayNulbeTpMDcim()', =0123456789-\\abc".unicodeScalars)
        for _ in 0..<4_000 {
            let length = Int(generator.next() % 40)
            var text = ""
            for _ in 0..<length { text.unicodeScalars.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
            let type = ClickHouseType.parse(text)
            _ = type.kind
            _ = type.description
            _ = type.isComposite
        }
    }
}

/// Deterministic PRNG for fuzz tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
