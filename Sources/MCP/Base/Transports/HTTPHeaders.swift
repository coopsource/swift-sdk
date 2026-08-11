import CoreFoundation
import Foundation

package struct ToolHeaderPlan: Hashable, Sendable {
    package enum ValueType: Hashable, Sendable {
        case string
        case integer
        case boolean
    }

    package struct Field: Hashable, Sendable {
        let headerName: String
        let propertyPath: [String]
        let valueType: ValueType
    }

    let toolName: String
    let fields: [Field]

    package init(tool: Tool) throws {
        guard Self.containsAnnotation(tool.inputSchema) else {
            self.toolName = tool.name
            self.fields = []
            return
        }
        guard let schema = tool.inputSchema.objectValue,
            schema["type"]?.stringValue == "object"
        else {
            throw MCPError.invalidParams(
                "Tool \(tool.name) inputSchema must have object type")
        }

        var fields: [Field] = []
        var usedNames: Set<String> = []
        try Self.collectReachableFields(
            in: schema,
            path: [],
            toolName: tool.name,
            fields: &fields,
            usedNames: &usedNames
        )
        self.toolName = tool.name
        self.fields = fields.sorted {
            let leftName = $0.headerName.lowercased()
            let rightName = $1.headerName.lowercased()
            if leftName != rightName { return leftName < rightName }
            return $0.propertyPath.joined(separator: ".")
                < $1.propertyPath.joined(separator: ".")
        }
    }

    private static func collectReachableFields(
        in schema: [String: Value],
        path: [String],
        toolName: String,
        fields: inout [Field],
        usedNames: inout Set<String>
    ) throws {
        if path.isEmpty, schema["x-mcp-header"] != nil {
            throw invalidAnnotation(toolName, "x-mcp-header cannot annotate the schema root")
        }

        for (key, value) in schema where key != "properties" && key != "x-mcp-header" {
            if containsAnnotation(value) {
                throw invalidAnnotation(
                    toolName,
                    "x-mcp-header is not statically reachable through properties")
            }
        }

        guard let propertiesValue = schema["properties"] else { return }
        guard let properties = propertiesValue.objectValue else {
            throw invalidAnnotation(toolName, "inputSchema properties must be an object")
        }

        for (propertyName, propertyValue) in properties {
            guard let propertySchema = propertyValue.objectValue else {
                if containsAnnotation(propertyValue) {
                    throw invalidAnnotation(toolName, "x-mcp-header must annotate a property schema")
                }
                continue
            }

            let propertyPath = path + [propertyName]
            if let annotation = propertySchema["x-mcp-header"] {
                guard let name = annotation.stringValue,
                    !name.isEmpty,
                    isHTTPToken(name)
                else {
                    throw invalidAnnotation(
                        toolName, "x-mcp-header must be a non-empty HTTP field-name token")
                }

                let lowercaseName = name.lowercased()
                guard usedNames.insert(lowercaseName).inserted else {
                    throw invalidAnnotation(
                        toolName, "x-mcp-header values must be case-insensitively unique")
                }

                let valueType: ValueType
                switch propertySchema["type"]?.stringValue {
                case "string": valueType = .string
                case "integer": valueType = .integer
                case "boolean": valueType = .boolean
                default:
                    throw invalidAnnotation(
                        toolName,
                        "x-mcp-header can only annotate string, integer, or boolean properties")
                }
                fields.append(Field(
                    headerName: HTTPHeaderName.parameterPrefix + name,
                    propertyPath: propertyPath,
                    valueType: valueType
                ))
            }

            if propertySchema["properties"] != nil {
                guard propertySchema["type"]?.stringValue == "object" else {
                    throw invalidAnnotation(
                        toolName,
                        "nested x-mcp-header properties require an object property path")
                }
                try collectReachableFields(
                    in: propertySchema,
                    path: propertyPath,
                    toolName: toolName,
                    fields: &fields,
                    usedNames: &usedNames
                )
            } else {
                for (key, value) in propertySchema
                where key != "x-mcp-header" && containsAnnotation(value) {
                    throw invalidAnnotation(
                        toolName,
                        "x-mcp-header is not statically reachable through properties")
                }
            }
        }
    }

    private static func containsAnnotation(_ value: Value) -> Bool {
        switch value {
        case .object(let object):
            return object["x-mcp-header"] != nil
                || object.values.contains(where: containsAnnotation)
        case .array(let values):
            return values.contains(where: containsAnnotation)
        default:
            return false
        }
    }

    private static func invalidAnnotation(_ toolName: String, _ reason: String) -> MCPError {
        .invalidParams("Invalid tool \(toolName): \(reason)")
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        !value.utf8.isEmpty && value.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122:
                return true
            case 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                return true
            default:
                return false
            }
        }
    }
}

package enum MCPHTTPHeaders {
    private static let base64Prefix = "=?base64?"
    private static let base64Suffix = "?="
    private static let maximumSafeInteger = 9_007_199_254_740_991.0

    package static func requestHeaders(
        for data: Data,
        toolPlans: [String: ToolHeaderPlan]
    ) throws -> [String: String] {
        let object = try requestObject(from: data)
        guard let method = object["method"] as? String, isPlainHeaderValue(method) else {
            throw MCPError.invalidRequest("JSON-RPC method is not a safe HTTP header value")
        }

        var headers = [HTTPHeaderName.mcpMethod: method]
        guard let parameters = object["params"] as? [String: Any] else {
            return headers
        }

        if let name = requestName(method: method, parameters: parameters) {
            headers[HTTPHeaderName.mcpName] = encode(name)
        }

        guard method == CallTool.name,
            let toolName = parameters["name"] as? String,
            let plan = toolPlans[toolName],
            let arguments = parameters["arguments"] as? [String: Any]
        else {
            return headers
        }

        for field in plan.fields {
            guard let value = value(at: field.propertyPath, in: arguments),
                !(value is NSNull)
            else {
                continue
            }
            let string = try stringValue(
                value,
                type: field.valueType,
                headerName: field.headerName
            )
            headers[field.headerName] = encode(string)
        }
        return headers
    }

    package static func validationFailure(
        for request: HTTPRequest,
        toolPlans: [String: ToolHeaderPlan]
    ) -> String? {
        guard let body = request.body,
            let object = try? requestObject(from: body),
            let method = object["method"] as? String
        else {
            return "Mcp-Method cannot be compared with the request body"
        }

        guard let methodHeader = singleHeader(HTTPHeaderName.mcpMethod, in: request),
            isPlainHeaderValue(methodHeader),
            methodHeader == method
        else {
            return "Mcp-Method is missing, malformed, or does not match the request body"
        }

        let parameters = object["params"] as? [String: Any] ?? [:]
        if let expectedName = requestName(method: method, parameters: parameters) {
            guard let nameHeader = singleHeader(HTTPHeaderName.mcpName, in: request),
                let decodedName = try? decode(nameHeader),
                decodedName == expectedName
            else {
                return "Mcp-Name is missing, malformed, or does not match the request body"
            }
        }

        guard method == CallTool.name,
            let toolName = parameters["name"] as? String,
            let plan = toolPlans[toolName]
        else {
            return nil
        }

        let arguments = parameters["arguments"] as? [String: Any] ?? [:]
        for field in plan.fields {
            let bodyValue = value(at: field.propertyPath, in: arguments)
            let headerValue = singleHeader(field.headerName, in: request)

            if bodyValue == nil || bodyValue is NSNull {
                if headerValue != nil {
                    return "\(field.headerName) must be omitted when its parameter is absent or null"
                }
                continue
            }

            guard let headerValue,
                let decoded = try? decode(headerValue),
                valuesMatch(decoded, bodyValue: bodyValue!, type: field.valueType)
            else {
                return "\(field.headerName) is missing, malformed, or does not match the request body"
            }
        }
        return nil
    }

    package static func toolName(in data: Data) -> String? {
        guard let object = try? requestObject(from: data),
            object["method"] as? String == CallTool.name,
            let parameters = object["params"] as? [String: Any]
        else {
            return nil
        }
        return parameters["name"] as? String
    }

    private static func requestObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidRequest("JSON-RPC message must be an object")
        }
        return object
    }

    private static func requestName(
        method: String,
        parameters: [String: Any]
    ) -> String? {
        switch method {
        case CallTool.name, GetPrompt.name:
            return parameters["name"] as? String
        case ReadResource.name:
            return parameters["uri"] as? String
        default:
            return nil
        }
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        var value: Any = object
        for component in path {
            guard let current = value as? [String: Any],
                let next = current[component]
            else {
                return nil
            }
            value = next
        }
        return value
    }

    private static func stringValue(
        _ value: Any,
        type: ToolHeaderPlan.ValueType,
        headerName: String
    ) throws -> String {
        switch type {
        case .string:
            guard let string = value as? String else {
                throw MCPError.invalidParams("\(headerName) parameter must be a string")
            }
            return string
        case .boolean:
            guard let number = value as? NSNumber, isBoolean(number) else {
                throw MCPError.invalidParams("\(headerName) parameter must be a boolean")
            }
            return number.boolValue ? "true" : "false"
        case .integer:
            guard let number = value as? NSNumber,
                !isBoolean(number),
                abs(number.doubleValue) <= maximumSafeInteger,
                number.doubleValue.rounded() == number.doubleValue
            else {
                throw MCPError.invalidParams(
                    "\(headerName) parameter must be a safe integer")
            }
            return String(Int64(number.doubleValue))
        }
    }

    private static func valuesMatch(
        _ headerValue: String,
        bodyValue: Any,
        type: ToolHeaderPlan.ValueType
    ) -> Bool {
        switch type {
        case .string:
            return bodyValue as? String == headerValue
        case .boolean:
            guard let number = bodyValue as? NSNumber, isBoolean(number) else { return false }
            return headerValue == (number.boolValue ? "true" : "false")
        case .integer:
            guard let number = bodyValue as? NSNumber,
                !isBoolean(number),
                abs(number.doubleValue) <= maximumSafeInteger,
                number.doubleValue.rounded() == number.doubleValue,
                let headerNumber = Double(headerValue),
                abs(headerNumber) <= maximumSafeInteger,
                headerNumber.rounded() == headerNumber
            else {
                return false
            }
            return headerNumber == number.doubleValue
        }
    }

    private static func encode(_ value: String) -> String {
        guard !shouldEncode(value) else {
            return base64Prefix + Data(value.utf8).base64EncodedString() + base64Suffix
        }
        return value
    }

    private static func decode(_ value: String) throws -> String {
        if value.hasPrefix(base64Prefix), value.hasSuffix(base64Suffix) {
            let payload = value.dropFirst(base64Prefix.count).dropLast(base64Suffix.count)
            guard let data = Data(base64Encoded: String(payload)),
                let decoded = String(data: data, encoding: .utf8)
            else {
                throw MCPError.invalidRequest("Malformed Base64 MCP header value")
            }
            return decoded
        }
        guard isPlainHeaderValue(value) else {
            throw MCPError.invalidRequest("Malformed MCP header value")
        }
        return value
    }

    private static func shouldEncode(_ value: String) -> Bool {
        !isPlainHeaderValue(value)
            || (value.hasPrefix(base64Prefix) && value.hasSuffix(base64Suffix))
    }

    private static func isPlainHeaderValue(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.allSatisfy({ $0 == 0x09 || (0x20...0x7e).contains($0) }) else {
            return false
        }
        guard let first = bytes.first, let last = bytes.last else { return true }
        return first != 0x09 && first != 0x20 && last != 0x09 && last != 0x20
    }

    private static func singleHeader(_ name: String, in request: HTTPRequest) -> String? {
        let matches = request.headers.filter {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }
        guard matches.count == 1 else { return nil }
        guard var value = matches.first?.value[...] else { return nil }
        while value.first == " " || value.first == "\t" {
            value.removeFirst()
        }
        while value.last == " " || value.last == "\t" {
            value.removeLast()
        }
        return String(value)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
