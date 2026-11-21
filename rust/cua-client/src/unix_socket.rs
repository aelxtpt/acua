use std::{io, os::unix::net::UnixStream, path::Path};

pub(super) fn connect(path: &Path) -> io::Result<UnixStream> {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;
        if path.as_os_str().as_bytes().len() > 103 {
            return connect_long(path);
        }
    }
    UnixStream::connect(path)
}

// A long absolute path is resolved through an open parent directory and a
// short sockaddr_un basename.
// Use a dedicated thread so an embedding caller's pthread directory, including
// an existing private directory selection, is never changed or cleared.
#[cfg(target_os = "macos")]
fn connect_long(path: &Path) -> io::Result<UnixStream> {
    use std::{fs::File, os::{fd::AsRawFd, unix::ffi::OsStrExt}, thread};

    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid or overlong Unix socket basename");
    let raw = path.as_os_str().as_bytes();
    let leaf = raw.rsplit(|byte| *byte == b'/').next().ok_or_else(invalid)?;
    // Do not reinterpret a trailing separator/dot as a different endpoint.
    if leaf.is_empty() || leaf == b"." || leaf == b".." || leaf.len() > 103 || raw.contains(&0) {
        return Err(invalid());
    }
    let name = path.file_name().ok_or_else(invalid)?.to_owned();
    // Open on the calling thread so relative paths retain its effective cwd.
    // File's descriptor is close-on-exec and stays owned until connect returns.
    let parent = File::open(path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new(".")))?;
    thread::Builder::new().name("cua-socket-connect".into()).spawn(move || {
        extern "C" { fn pthread_fchdir_np(fd: libc::c_int) -> libc::c_int; }
        struct ResetDirectory;
        impl Drop for ResetDirectory {
            fn drop(&mut self) { unsafe { pthread_fchdir_np(-1); } }
        }
        if unsafe { pthread_fchdir_np(parent.as_raw_fd()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let _reset = ResetDirectory;
        UnixStream::connect(Path::new(&name))
    })?.join().map_err(|_| io::Error::new(io::ErrorKind::Other, "Unix socket connection worker panicked"))?
}
