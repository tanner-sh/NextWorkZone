//! Windows 实现：剪贴板序号、前台窗口与 SendInput。

use windows_sys::Win32::Foundation::{CloseHandle, HWND};
use windows_sys::Win32::System::DataExchange::{GetClipboardSequenceNumber, IsClipboardFormatAvailable, RegisterClipboardFormatW};
use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, SendInput, VK_CONTROL, VK_LBUTTON, VK_V,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId, IsIconic, SW_RESTORE, SetForegroundWindow, ShowWindow};

use crate::apps::AppInfo;

/// 写入方用来标记“不要记录”的格式（剪贴板历史和剪贴板工具的约定）。
const CONCEALED_FORMATS: &[&str] = &["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore"];

pub fn change_count() -> i64 {
    // SAFETY: 无参数的系统调用
    unsafe { GetClipboardSequenceNumber() as i64 }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

pub fn is_concealed() -> bool {
    CONCEALED_FORMATS.iter().any(|name| {
        let name = wide(name);
        // SAFETY: name 是以 0 结尾的 UTF-16 字符串
        unsafe {
            let format = RegisterClipboardFormatW(name.as_ptr());
            format != 0 && IsClipboardFormatAvailable(format) != 0
        }
    })
}

pub fn frontmost() -> Option<AppInfo> {
    // SAFETY: 句柄只用于查询，打开的进程句柄在函数内关闭
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.is_null() {
            return None;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, &mut pid);
        let path = process_path(pid);
        let file = path.as_deref().and_then(|p| p.rsplit(['\\', '/']).next()).map(str::to_string);
        let name = file.as_deref().map(|f| f.strip_suffix(".exe").or_else(|| f.strip_suffix(".EXE")).unwrap_or(f).to_string());
        Some(AppInfo {
            id: file.map(|f| f.to_lowercase()).unwrap_or_else(|| format!("pid:{pid}")),
            name: name.unwrap_or_else(|| "未知应用".into()),
            path,
            pid: Some(pid),
            window: Some(hwnd as isize),
        })
    }
}

/// 进程的可执行文件路径。
unsafe fn process_path(pid: u32) -> Option<String> {
    // SAFETY: 由调用方保证；句柄在使用后关闭
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buffer = [0u16; 1024];
        let mut len = buffer.len() as u32;
        let ok = QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut len) != 0;
        CloseHandle(process);
        ok.then(|| String::from_utf16_lossy(&buffer[..len as usize]))
    }
}

pub fn activate(app: &AppInfo) -> bool {
    let Some(window) = app.window else { return false };
    let hwnd = window as HWND;
    // SAFETY: 窗口句柄失效时调用只是失败
    unsafe {
        if IsIconic(hwnd) != 0 {
            ShowWindow(hwnd, SW_RESTORE);
        }
        SetForegroundWindow(hwnd) != 0
    }
}

pub fn left_button_down() -> bool {
    // SAFETY: 只读取按键状态
    unsafe { GetAsyncKeyState(VK_LBUTTON as i32) as u16 & 0x8000 != 0 }
}

fn key(vk: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { 0 }, time: 0, dwExtraInfo: 0 },
        },
    }
}

pub fn send_paste() -> Result<(), String> {
    let inputs = [key(VK_CONTROL, false), key(VK_V, false), key(VK_V, true), key(VK_CONTROL, true)];
    // SAFETY: inputs 在调用期间有效
    let sent = unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), size_of::<INPUT>() as i32) };
    if sent as usize == inputs.len() { Ok(()) } else { Err("模拟粘贴被系统拒绝".into()) }
}
