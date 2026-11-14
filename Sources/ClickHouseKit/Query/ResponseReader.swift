import ClickHouseWire
import Foundation

/// Turns a streaming HTTP response into a `QueryResult` (designs D3, D4, D9).
enum ResponseReader {
    static let errorBodyLimit = 64 * 1024
    static let rawTextLimit = 16 * 1024 * 1024
    /// Raw bytes kept when the server did not announce a format, to fall back to raw text.
    static let unannouncedFormatSample = 1024 * 1024

    struct Outcome: Sendable {
        let result: QueryResult
        /// Reading stopped before the server finished (limits): the server-side query may still run.
        let stoppedEarly: Bool
    }

    /// The error carried by a non-2xx response or an exception header.
    static func error(from response: HTTPStreamingResponse) async -> ClickHouseError {
        let status = response.head.status
        let body = (try? await response.collect(limit: errorBodyLimit)) ?? Data()
        let text = String(decoding: body, as: UTF8.self)
        if let exception = ClickHouseServerException.parse(text) {
            return .server(exception, httpStatus: status)
        }
        if let code = response.head.header("x-clickhouse-exception-code").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .server(ClickHouseServerException(code: code, name: nil, message: message.isEmpty ? "Server error \(code)" : message), httpStatus: status)
        }
        let detail = summarize(text)
        if status == 401 || status == 403 || status == 407 {
            return ClickHouseError(.authentication, detail.isEmpty ? "Access denied (HTTP \(status))" : "Access denied (HTTP \(status)): \(detail)",
                                   httpStatus: status)
        }
        return ClickHouseError(.server, detail.isEmpty ? "The server answered HTTP \(status)" : "HTTP \(status): \(detail)", httpStatus: status)
    }

    /// First meaningful text of a non-ClickHouse error body (proxies, HTML pages), bounded.
    static func summarize(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        cleaned = cleaned.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return String(cleaned.prefix(500))
    }

    static func read(_ response: HTTPStreamingResponse, queryID: String, limits: RowLimits,
                     onResponse: (@Sendable (ResponseInfo) -> Void)?) async throws -> Outcome {
        let head = response.head
        guard (200..<300).contains(head.status), head.header("x-clickhouse-exception-code") == nil else {
            throw await error(from: response)
        }
        let format = head.header("x-clickhouse-format")?.trimmingCharacters(in: .whitespaces)
        let displayName = head.header("x-clickhouse-server-display-name")
        let summary = head.header("x-clickhouse-summary").flatMap { QueryProgress.latest(fromHeaderValues: [$0]) }
        let progress = head.header("x-clickhouse-progress").flatMap { QueryProgress.latest(fromHeaderValues: [$0]) }
        onResponse?(ResponseInfo(queryID: queryID, serverDisplayName: displayName, format: format, progress: summary ?? progress))

        if let format, !format.isEmpty, format != RequestBuilder.resultFormat {
            return try await readRaw(response, queryID: queryID, format: format, limits: limits, summary: summary, displayName: displayName)
        }

        var parser = TSVResultParser(exceptionTag: head.header("x-clickhouse-exception-tag"), maxLineBytes: limits.maxLineBytes)
        var rows: [[String?]] = []
        var binaryCells: [QueryResult.CellAddress: Data] = [:]
        func collectBinary() {
            for cell in parser.takeBinaryCells() where cell.row < limits.maxRows {
                binaryCells[QueryResult.CellAddress(row: cell.row, column: cell.column)] = cell.bytes
            }
        }
        var consumed = 0
        var stoppedEarly = false
        var sample: Data? = format == nil ? Data() : nil
        do {
            for try await chunk in response.body {
                consumed += chunk.count
                if var current = sample {
                    current.append(chunk.prefix(max(0, unannouncedFormatSample - current.count)))
                    sample = current
                }
                let parsed = try parser.consume(chunk)
                response.acknowledge(chunk.count)
                collectBinary()
                if parser.isInTrailer {
                    // The server reported an exception after these rows: it wins over any limit. Its text
                    // may continue in later chunks, so read on until it is complete or the stream ends
                    // (the parser caps the trailer, so this reads at most 64 KB more).
                    rows += parsed
                    if parser.isTrailerComplete {
                        response.cancel()
                        break
                    }
                    continue
                }
                if rows.count + parsed.count > limits.maxRows {
                    // More rows than allowed exist: keep the first `maxRows` and stop reading.
                    rows += parsed.prefix(max(0, limits.maxRows - rows.count))
                    stoppedEarly = true
                    break
                }
                rows += parsed
                if consumed > limits.maxBytes {
                    stoppedEarly = true
                    break
                }
            }
        } catch let error as ClickHouseServerException {
            throw ClickHouseError.server(error)
        } catch let error as TSVParseError {
            response.cancel()
            if let sample, case .malformedRow = error { return rawOutcome(sample, queryID: queryID, format: "unknown", summary: summary, displayName: displayName, truncated: true) }
            throw ClickHouseError(.protocolViolation, error.description)
        } catch {
            // Transport failure after the head: the parser decides whether a server exception explains it.
            if Task.isCancelled { throw ClickHouseError.cancelled() }
            let transportError = ClickHouseError.transport(error)
            if transportError.kind == .cancelled { throw transportError }
            do {
                _ = try parser.finish(abruptly: true)
            } catch let exception as ClickHouseServerException {
                throw ClickHouseError.server(exception)
            } catch {}
            throw transportError
        }
        if Task.isCancelled {
            response.cancel()
            throw ClickHouseError.cancelled()
        }
        if stoppedEarly {
            response.cancel()
            // An exception already received (held back or in the trailer) wins over the truncated rows;
            // an incomplete last row is irrelevant because the result is truncated anyway.
            do {
                _ = try parser.finish(abruptly: false)
            } catch let exception as ClickHouseServerException {
                throw ClickHouseError.server(exception)
            } catch {}
        } else {
            do {
                let last = try parser.finish(abruptly: false)
                collectBinary()
                if rows.count + last.count > limits.maxRows {
                    rows += last.prefix(max(0, limits.maxRows - rows.count))
                    stoppedEarly = true
                } else {
                    rows += last
                }
            } catch let exception as ClickHouseServerException {
                throw ClickHouseError.server(exception)
            } catch let error as TSVParseError {
                if let sample, case .malformedRow = error { return rawOutcome(sample, queryID: queryID, format: "unknown", summary: summary, displayName: displayName, truncated: false) }
                throw ClickHouseError(.protocolViolation, error.description)
            }
        }
        let result = QueryResult(columns: parser.columns ?? [], rows: rows, isTruncated: stoppedEarly, queryID: queryID, summary: summary,
                                 serverDisplayName: displayName, binaryCells: binaryCells)
        return Outcome(result: result, stoppedEarly: stoppedEarly)
    }

    private static func readRaw(_ response: HTTPStreamingResponse, queryID: String, format: String, limits: RowLimits,
                                summary: QueryProgress?, displayName: String?) async throws -> Outcome {
        let cap = min(limits.maxBytes, rawTextLimit)
        var data = Data()
        var truncated = false
        do {
            for try await chunk in response.body {
                response.acknowledge(chunk.count)
                data.append(chunk.prefix(max(0, cap - data.count)))
                if data.count >= cap {
                    truncated = true
                    break
                }
            }
        } catch {
            if Task.isCancelled { throw ClickHouseError.cancelled() }
            let text = String(decoding: data.suffix(errorBodyLimit), as: UTF8.self)
            if let exception = ClickHouseServerException.parse(text) { throw ClickHouseError.server(exception) }
            throw ClickHouseError.transport(error)
        }
        if Task.isCancelled { throw ClickHouseError.cancelled() }
        if truncated { response.cancel() }
        return Outcome(result: rawOutcome(data, queryID: queryID, format: format, summary: summary, displayName: displayName, truncated: truncated).result,
                       stoppedEarly: truncated)
    }

    private static func rawOutcome(_ data: Data, queryID: String, format: String, summary: QueryProgress?, displayName: String?,
                                   truncated: Bool) -> Outcome {
        let result = QueryResult(columns: [], rows: [], isTruncated: truncated, queryID: queryID, summary: summary, serverDisplayName: displayName,
                                 format: format, rawText: String(decoding: data, as: UTF8.self))
        return Outcome(result: result, stoppedEarly: truncated)
    }
}
