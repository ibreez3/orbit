#[cfg(windows)]
pub fn pipe_name() -> String {
    let user = std::env::var("USERNAME").unwrap_or_default();
    let name: String = user.chars().map(|ch| if ch.is_alphanumeric() { ch } else { '_' }).collect();
    format!(r"\\.\pipe\OrbitAgent-{name}")
}

#[cfg(windows)]
pub fn create_pipe(first: bool) -> std::io::Result<tokio::net::windows::named_pipe::NamedPipeServer> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::{Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW, SECURITY_ATTRIBUTES};
    let sddl: Vec<u16> = "D:P(A;;GA;;;OW)(A;;GA;;;SY)\0".encode_utf16().collect();
    let mut descriptor = std::ptr::null_mut();
    unsafe {
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), 1, &mut descriptor, std::ptr::null_mut()) == 0 { return Err(std::io::Error::last_os_error()); }
        let attributes = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: descriptor, bInheritHandle: 0 };
        let result = tokio::net::windows::named_pipe::ServerOptions::new().first_pipe_instance(first).reject_remote_clients(true).create_with_security_attributes_raw(pipe_name(), &attributes as *const _ as *mut _);
        LocalFree(descriptor);
        result
    }
}
