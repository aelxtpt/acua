use super::*;
use std::{
    ffi::OsString,
    fs::{self, File},
    os::unix::{ffi::OsStringExt, net::UnixListener},
    sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Arc},
};

extern "C" { fn pthread_fchdir_np(fd: libc::c_int) -> libc::c_int; }

struct OwnedDirectory(PathBuf);
static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(0);
impl OwnedDirectory {
    fn new() -> Self {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let sequence = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
        let root = PathBuf::from(format!("/private/tmp/cua-rust-long-{}-{nonce}-{sequence}", std::process::id()));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
}
impl Drop for OwnedDirectory { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }

// The server binds using Darwin's thread directory, independently of the
// library's connection code. Its absolute endpoint exceeds sun_path's limit.
fn listener_at(path: &Path) -> UnixListener {
    let parent = File::open(path.parent().unwrap()).unwrap();
    let name = path.file_name().unwrap().to_owned();
    thread::spawn(move || {
        assert_eq!(unsafe { pthread_fchdir_np(parent.as_raw_fd()) }, 0);
        let listener = UnixListener::bind(Path::new(&name)).unwrap();
        assert_eq!(unsafe { pthread_fchdir_np(-1) }, 0);
        listener
    }).join().unwrap()
}

fn roundtrip(path: &Path) {
    assert!(path.as_os_str().as_bytes().len() > 103);
    let listener = listener_at(path);
    listener.set_nonblocking(true).unwrap();
    let cancel = Arc::new(AtomicBool::new(false));
    let stop = Arc::clone(&cancel);
    let server = thread::spawn(move || {
        let end = Instant::now() + Duration::from_secs(3);
        while !stop.load(Ordering::Acquire) && Instant::now() < end {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    handshake(&mut stream);
                    let request = read_frame(&mut stream);
                    assert_eq!(request["params"]["requestType"], "ComputerUseIPCListAppsRequest");
                    send(&mut stream, json!({"jsonrpc":"2.0","id":request["id"],"result":[]}));
                    return true;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => thread::sleep(Duration::from_millis(1)),
                Err(error) => panic!("accept: {error}"),
            }
        }
        false
    });
    let result = Client::connect_with_options(path, ClientOptions { timeout: Duration::from_secs(2), ..Default::default() });
    let apps = match result {
        Ok(mut client) => client.list_apps(),
        Err(error) => Err(error),
    };
    cancel.store(true, Ordering::Release);
    let served = server.join().unwrap();
    assert!(apps.expect("long socket connection and list_apps").is_empty());
    assert!(served);
}

#[test]
fn long_socket_handshake_and_rpc_preserve_unicode_spaces_percent_and_byte_errors() {
    let owned = OwnedDirectory::new();
    let parent = owned.0.join(format!("Política % {}", "d".repeat(80)));
    fs::create_dir(&parent).unwrap();
    roundtrip(&parent.join("owned.sock"));
    roundtrip(&parent.join(format!("{}.sock", "s".repeat(98))));
    // Compare an invalid filename's error with a direct short-path syscall;
    // APFS does not support binding a listener at this byte sequence.
    let name = OsString::from_vec(b"owned-\xff.sock".to_vec());
    let invalid = parent.join(&name);
    let directory = File::open(&parent).unwrap();
    let expected = thread::spawn(move || {
        assert_eq!(unsafe { pthread_fchdir_np(directory.as_raw_fd()) }, 0);
        let error = UnixStream::connect(Path::new(&name)).unwrap_err();
        assert_eq!(unsafe { pthread_fchdir_np(-1) }, 0);
        error.raw_os_error()
    }).join().unwrap();
    assert!(matches!(Client::connect_to(invalid), Err(Error::Io(error)) if error.raw_os_error() == expected));
}

#[test]
fn long_socket_keeps_the_callers_thread_directory_on_success_and_failure() {
    let owned = OwnedDirectory::new();
    let parent = owned.0.join("d".repeat(100));
    let caller = owned.0.join("caller");
    fs::create_dir(&parent).unwrap(); fs::create_dir(&caller).unwrap();
    fs::write(caller.join("marker"), b"caller").unwrap();
    let caller_directory = File::open(&caller).unwrap();
    thread::spawn(move || {
        assert_eq!(unsafe { pthread_fchdir_np(caller_directory.as_raw_fd()) }, 0);
        // The server helper runs on another thread and cannot clear this one.
        roundtrip(&parent.join("owned.sock"));
        assert_eq!(fs::read("marker").unwrap(), b"caller");
        let relative = PathBuf::from("..").join("d".repeat(100)).join("relative.sock");
        roundtrip(&relative);
        assert_eq!(fs::read("marker").unwrap(), b"caller");
        assert!(Client::connect_to(parent.join("absent.sock")).is_err());
        assert_eq!(fs::read("marker").unwrap(), b"caller");
        assert_eq!(unsafe { pthread_fchdir_np(-1) }, 0);
    }).join().unwrap();
}

#[test]
fn long_socket_rejects_overlong_basename_and_nul_without_changing_directory() {
    let owned = OwnedDirectory::new();
    let parent = owned.0.join("d".repeat(100)); fs::create_dir(&parent).unwrap();
    let before = std::env::current_dir().unwrap();
    assert!(Client::connect_to(parent.join("s".repeat(104))).is_err());
    assert!(Client::connect_to(parent.join(OsString::from_vec(b"owned\0.sock".to_vec()))).is_err());
    assert_eq!(std::env::current_dir().unwrap(), before);
}
