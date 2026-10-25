import Foundation
import NWZCore

typealias JSONValue = NWZCore.JSONValue

/// 命令参数：值可以是基本类型、数组、字典、`nil` 或任意 `Encodable`。
struct Args {
    var values: [String: JSONValue] = [:]

    subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }
}

/// 把 Swift 值转换为命令参数中的 JSON 值。
func json(_ value: (any Encodable)?) -> JSONValue {
    guard let value else { return .null }
    if let v = value as? JSONValue { return v }
    return JSONValue.from(AnyEncodable(value))
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
