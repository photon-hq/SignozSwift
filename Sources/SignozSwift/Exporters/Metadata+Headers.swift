import GRPCCore

extension Metadata {
    init(headers: [(String, String)]) {
        self.init()
        for (key, value) in headers {
            addString(value, forKey: key)
        }
    }
}
