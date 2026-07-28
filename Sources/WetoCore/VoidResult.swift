import Foundation

/// `Result<Void, _>` нельзя сравнивать на равенство: `Void` не `Equatable`.
/// Границы возвращают именно такой результат, поэтому нужен явный доступ
/// к успеху и к ошибке — и в коде приложения, и в тестах.
extension Result where Success == Void {

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
