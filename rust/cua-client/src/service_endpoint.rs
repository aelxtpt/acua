use crate::{Error, Result};
use std::path::{Path, PathBuf};

#[cfg(target_os = "macos")]
const SERVICE_BUNDLE_IDENTIFIER: &str = "com.aex.computeruse";

/// Resolves a service application's configured Unix endpoint without launching it.
/// On macOS, CoreFoundation reads XML and binary Info.plist files. The bundle
/// must declare its application group; without one there is no shared socket.
pub fn service_bundle_socket_path(bundle: impl AsRef<Path>) -> Result<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var_os("HOME")
            .filter(|p| !p.is_empty())
            .ok_or_else(|| Error::InvalidInput("HOME is missing; use Client::connect_to".into()))?;
        let metadata = macos::metadata(bundle.as_ref())?;
        if metadata.identifier.as_deref() != Some(SERVICE_BUNDLE_IDENTIFIER) {
            return Err(Error::InvalidInput(
                "bundle is not a supported CUA service application".into(),
            ));
        }
        endpoint(Path::new(&home), metadata.group)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = bundle;
        Err(Error::InvalidInput(
            "service bundle discovery requires macOS; use Client::connect_to".into(),
        ))
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn installed_service_socket_path(home: &Path) -> Result<Option<PathBuf>> {
    // Same root as `make install` (SERVICE_DIR) and the helper's discovery.
    let configuration = std::env::var_os("AEX_COMPUTER_USE_HOME")
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("Library/Application Support/Aex Computer Use"));
    configured_service_socket_path(home, &configuration)
}

#[cfg(target_os = "macos")]
pub(crate) fn configured_service_socket_path(
    home: &Path,
    configuration: &Path,
) -> Result<Option<PathBuf>> {
    for name in ["AexComputerUseService.app", "Aex Computer Use.app"] {
        let bundle = configuration.join("computer-use").join(name);
        if !bundle.is_dir() {
            continue;
        }
        let metadata = macos::metadata(&bundle)?;
        // Client approval bundles must never be mistaken for service bundles.
        if metadata.identifier.as_deref() == Some(SERVICE_BUNDLE_IDENTIFIER) {
            return endpoint(home, metadata.group).map(Some);
        }
    }
    Ok(None)
}

#[cfg(target_os = "macos")]
fn endpoint(home: &Path, group: Option<String>) -> Result<PathBuf> {
    let Some(group) = group.as_deref() else {
        return Err(Error::InvalidInput(
            "service bundle declares no application group; use Client::connect_to".into(),
        ));
    };
    if group.is_empty() {
        return Err(Error::InvalidInput(
            "service bundle disables the shared socket; use Client::connect_to".into(),
        ));
    }
    if group == "." || group == ".." || group.contains('/') || group.contains('\0') {
        return Err(Error::InvalidInput(
            "service application group must be one path component".into(),
        ));
    }
    Ok(home
        .join("Library/Group Containers")
        .join(group)
        .join("IPC/computeruse.sock"))
}

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use std::{
        ffi::{c_char, c_void, CStr},
        os::unix::ffi::OsStrExt,
        ptr,
    };
    type Ref = *const c_void;
    const UTF8: u32 = 0x0800_0100;
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFURLCreateFromFileSystemRepresentation(
            allocator: Ref,
            bytes: *const u8,
            length: isize,
            directory: u8,
        ) -> Ref;
        fn CFBundleCreate(allocator: Ref, url: Ref) -> Ref;
        fn CFBundleGetValueForInfoDictionaryKey(bundle: Ref, key: Ref) -> Ref;
        fn CFStringCreateWithBytes(
            allocator: Ref,
            bytes: *const u8,
            length: isize,
            encoding: u32,
            external: u8,
        ) -> Ref;
        fn CFGetTypeID(value: Ref) -> usize;
        fn CFStringGetTypeID() -> usize;
        fn CFStringGetLength(value: Ref) -> isize;
        fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) -> isize;
        fn CFStringGetCString(value: Ref, buffer: *mut c_char, length: isize, encoding: u32) -> u8;
        fn CFRelease(value: Ref);
    }
    struct Owned(Ref);
    impl Owned {
        fn new(value: Ref) -> Result<Self> {
            if value.is_null() {
                Err(Error::InvalidInput(
                    "could not read service bundle metadata".into(),
                ))
            } else {
                Ok(Self(value))
            }
        }
    }
    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe { CFRelease(self.0) }
        }
    }
    pub(super) struct Metadata {
        pub identifier: Option<String>,
        pub group: Option<String>,
    }
    fn string(bundle: Ref, key: &str) -> Result<Option<String>> {
        let key = Owned::new(unsafe {
            CFStringCreateWithBytes(ptr::null(), key.as_ptr(), key.len() as isize, UTF8, 0)
        })?;
        let value = unsafe { CFBundleGetValueForInfoDictionaryKey(bundle, key.0) };
        if value.is_null() {
            return Ok(None);
        }
        if unsafe { CFGetTypeID(value) != CFStringGetTypeID() } {
            return Err(Error::InvalidInput(
                "service bundle identifier and group metadata must be strings".into(),
            ));
        }
        let length = unsafe { CFStringGetLength(value) };
        let capacity = unsafe { CFStringGetMaximumSizeForEncoding(length, UTF8) }
            .checked_add(1)
            .filter(|n| *n > 0 && *n <= 1_048_576)
            .ok_or_else(|| {
                Error::InvalidInput("service bundle metadata string is too large".into())
            })?;
        let mut buffer = vec![0u8; capacity as usize];
        if unsafe { CFStringGetCString(value, buffer.as_mut_ptr().cast(), capacity, UTF8) } == 0 {
            return Err(Error::InvalidInput(
                "service bundle metadata is not valid UTF-8".into(),
            ));
        }
        let value = unsafe { CStr::from_ptr(buffer.as_ptr().cast()) }
            .to_str()
            .map_err(|_| {
                Error::InvalidInput("service bundle metadata is not valid UTF-8".into())
            })?;
        if value.encode_utf16().count() != length as usize {
            return Err(Error::InvalidInput(
                "service bundle metadata contains NUL".into(),
            ));
        }
        Ok(Some(value.to_owned()))
    }
    pub(super) fn metadata(path: &Path) -> Result<Metadata> {
        if !path.is_dir() {
            return Err(Error::InvalidInput(
                "service bundle directory does not exist".into(),
            ));
        }
        let absolute;
        let path = if path.is_absolute() {
            path
        } else {
            absolute = std::env::current_dir()?.join(path);
            &absolute
        };
        let bytes = path.as_os_str().as_bytes();
        let url = Owned::new(unsafe {
            CFURLCreateFromFileSystemRepresentation(
                ptr::null(),
                bytes.as_ptr(),
                bytes.len() as isize,
                1,
            )
        })?;
        let bundle = Owned::new(unsafe { CFBundleCreate(ptr::null(), url.0) })?;
        Ok(Metadata {
            identifier: string(bundle.0, "CFBundleIdentifier")?,
            group: string(bundle.0, "CUAApplicationGroupIdentifier")?,
        })
    }
}
