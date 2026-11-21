//! Foundation value decoding on the service's supported macOS platform.
#![cfg(target_os = "macos")]
use serde::{de::Error as _, Deserialize, Deserializer};
use std::{ffi::{c_char, c_void, CStr}, mem, ptr};
type Object = *mut c_void;
#[link(name = "Foundation", kind = "framework")]
extern "C" {
    #[link_name = "OBJC_CLASS_$_NSString"] static STRING_CLASS: u8;
    #[link_name = "OBJC_CLASS_$_NSURL"] static URL_CLASS: u8;
    #[link_name = "OBJC_CLASS_$_NSAutoreleasePool"] static POOL_CLASS: u8;
}
#[link(name = "objc")]
extern "C" { fn sel_registerName(name: *const c_char) -> Object; fn objc_msgSend(); }
unsafe fn selector(name: &'static [u8]) -> Object { sel_registerName(name.as_ptr().cast()) }
unsafe fn zero(object: Object, name: &'static [u8]) -> Object {
    let send: unsafe extern "C" fn(Object, Object) -> Object = mem::transmute(objc_msgSend as unsafe extern "C" fn());
    send(object, selector(name))
}
struct Pool(Object);
impl Drop for Pool { fn drop(&mut self) { unsafe { zero(self.0, b"drain\0"); } } }
struct Owned(Object);
impl Drop for Owned { fn drop(&mut self) { unsafe { zero(self.0, b"release\0"); } } }
unsafe fn string(value: &str) -> Owned {
    let object = zero(ptr::addr_of!(STRING_CLASS).cast_mut().cast(), b"alloc\0");
    let send: unsafe extern "C" fn(Object,Object,*const u8,usize,usize)->Object = mem::transmute(objc_msgSend as unsafe extern "C" fn());
    Owned(send(object, selector(b"initWithBytes:length:encoding:\0"), value.as_ptr(), value.len(), 4))
}
unsafe fn copy_string(value: Object) -> Option<String> {
    if value.is_null() { return None; }
    let bytes = zero(value, b"UTF8String\0").cast::<c_char>();
    if bytes.is_null() { return None; }
    CStr::from_ptr(bytes).to_str().ok().map(str::to_owned)
}
fn has_valid_scheme(value: &str) -> bool {
    let Some(colon) = value.find(':') else { return true; };
    if colon == 0 || value[..colon].contains(['/', '?', '#']) { return true; }
    let mut scheme = value[..colon].bytes();
    scheme.next().is_some_and(|c| c.is_ascii_alphabetic()) && scheme.all(|c| c.is_ascii_alphanumeric() || b"+-.".contains(&c))
}
fn url(value: &str) -> Option<String> {
    // Foundation.URL's Codable initializer rejects empty values and invalid
    // schemes that legacy NSURL can otherwise represent.
    if value.is_empty() || !has_valid_scheme(value) { return None; }
    unsafe {
        let _pool = Pool(zero(ptr::addr_of!(POOL_CLASS).cast_mut().cast(), b"new\0"));
        let text = string(value);
        if text.0.is_null() { return None; }
        let send: unsafe extern "C" fn(Object,Object,Object,bool)->Object = mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let object = send(ptr::addr_of!(URL_CLASS).cast_mut().cast(), selector(b"URLWithString:encodingInvalidCharacters:\0"), text.0, true);
        copy_string(zero(object, b"absoluteString\0"))
    }
}
pub(crate) fn deserialize_url<'de,D:Deserializer<'de>>(deserializer:D)->Result<String,D::Error> {
    url(&String::deserialize(deserializer)?).ok_or_else(||D::Error::custom("invalid native URL"))
}
pub(crate) fn deserialize_optional_url<'de,D:Deserializer<'de>>(deserializer:D)->Result<Option<String>,D::Error> {
    Option::<String>::deserialize(deserializer)?.map(|value|url(&value).ok_or_else(||D::Error::custom("invalid native URL"))).transpose()
}
