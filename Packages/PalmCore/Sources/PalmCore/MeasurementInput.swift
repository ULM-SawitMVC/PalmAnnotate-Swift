import Foundation

extension Measurements {
    public struct InputError: Error, Equatable, LocalizedError, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Kotlin `BunchMeasurements.parseInput`: blank optional values are nil, a comma is a decimal separator,
    /// and the first failure is returned as one message (not a number, required, or not above zero).
    public static func parse(weight: String, height: String, circumference: String, notes: String) throws -> Measurements {
        func number(_ text: String, _ label: String) throws -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
                throw InputError(message: "\(label) harus berupa angka.")
            }
            return value
        }
        let value = Measurements(weightKg: try number(weight, "Berat"), heightCm: try number(height, "Tinggi"),
                                 circumferenceCm: try number(circumference, "Lingkar"), notes: notes)
        if let message = value.validationError { throw InputError(message: message) }
        return value
    }
}
