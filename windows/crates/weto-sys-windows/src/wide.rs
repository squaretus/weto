//! Строки UTF-16 для Windows API.

/// Строка с нулём на конце — для параметров `PCWSTR`.
pub fn null_terminated(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Строка до первого нуля (или целиком, если нуля нет).
pub fn until_null(units: &[u16]) -> String {
    let end = units
        .iter()
        .position(|&unit| unit == 0)
        .unwrap_or(units.len());
    String::from_utf16_lossy(&units[..end])
}

/// Строка по указателю с нулём на конце. Нулевой указатель — пустая строка.
///
/// # Safety
/// `pointer` — нулевой или указывает на строку UTF-16 с нулём на конце,
/// живую на время вызова.
pub unsafe fn from_pointer(pointer: *const u16) -> String {
    if pointer.is_null() {
        return String::new();
    }
    let mut length = 0;
    while *pointer.add(length) != 0 {
        length += 1;
    }
    String::from_utf16_lossy(std::slice::from_raw_parts(pointer, length))
}
