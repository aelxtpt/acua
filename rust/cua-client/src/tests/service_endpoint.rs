use super::*;
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);

struct App {
    root: PathBuf,
}
impl App {
    fn bytes(bytes: &[u8]) -> Self {
        let root = env::temp_dir().join(format!(
            "cua-service-bundle-{}-{} 👋.app",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(root.join("Contents")).unwrap();
        fs::write(root.join("Contents/Info.plist"), bytes).unwrap();
        Self { root }
    }
    fn xml(identifier: &str, value: &str) -> Self {
        Self::bytes(&Self::plist(identifier, value))
    }
    fn plist(identifier: &str, value: &str) -> Vec<u8> {
        format!("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>{identifier}</string><key>CFBundlePackageType</key><string>APPL</string>{value}</dict></plist>").into_bytes()
    }
}
impl Drop for App {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}

#[test]
fn service_bundle_uses_its_own_group_from_xml_and_binary_metadata() {
    let group = "KS98C89L5H.com.aex.computeruse";
    let expected = PathBuf::from(env::var_os("HOME").unwrap())
        .join("Library/Group Containers")
        .join(group)
        .join("IPC/computeruse.sock");
    let xml = App::xml(
        "com.aex.computeruse",
        &format!("<key>CUAApplicationGroupIdentifier</key><string>{group}</string>"),
    );
    let binary = App::bytes(include_bytes!("service-bundle.binary.plist"));
    assert_eq!(service_bundle_socket_path(&xml.root).unwrap(), expected);
    assert_eq!(service_bundle_socket_path(&binary.root).unwrap(), expected);
    let cwd = env::current_dir().unwrap();
    let mut relative = PathBuf::new();
    for component in cwd.components() {
        if matches!(component, std::path::Component::Normal(_)) {
            relative.push("..");
        }
    }
    relative.push(xml.root.strip_prefix("/").unwrap());
    assert_eq!(service_bundle_socket_path(relative).unwrap(), expected);
    assert_eq!(env::current_dir().unwrap(), cwd);
    let mut bytes = include_bytes!("service-bundle.binary.plist").to_vec();
    let start = bytes
        .windows(group.len())
        .position(|v| v == group.as_bytes())
        .unwrap();
    bytes[start + 5] = 0;
    let nul = App::bytes(&bytes);
    assert!(matches!(
        service_bundle_socket_path(&nul.root),
        Err(Error::InvalidInput(_))
    ));
}

#[test]
fn service_bundle_without_group_metadata_has_no_endpoint() {
    let app = App::xml("com.aex.computeruse", "");
    assert!(matches!(
        service_bundle_socket_path(&app.root),
        Err(Error::InvalidInput(_))
    ));
}

#[test]
fn disabled_malformed_or_foreign_bundle_metadata_is_rejected() {
    for value in [
        "<string></string>",
        "<integer>7</integer>",
        "<array/>",
        "<string>../foreign</string>",
        "<string>/foreign</string>",
        "<string>.</string>",
        "<string>..</string>",
    ] {
        let app = App::xml(
            "com.aex.computeruse",
            &format!("<key>CUAApplicationGroupIdentifier</key>{value}"),
        );
        assert!(matches!(
            service_bundle_socket_path(&app.root),
            Err(Error::InvalidInput(_))
        ));
    }
    for id in [
        "com.aex.computeruse.client",
        "com.example.unrelated",
        "com.example.other.CUAService",
        "",
    ] {
        let app=App::xml(id,"<key>CUAApplicationGroupIdentifier</key><string>KS98C89L5H.com.aex.computeruse</string>");
        assert!(matches!(
            service_bundle_socket_path(&app.root),
            Err(Error::InvalidInput(_))
        ));
    }
    assert!(service_bundle_socket_path("/private/tmp/cua-nonexistent-service-bundle.app").is_err());
}

#[test]
fn installed_service_search_uses_service_metadata_and_preserves_name_priority() {
    use crate::service_endpoint::configured_service_socket_path;
    for name in ["AexComputerUseService.app", "Aex Computer Use.app"] {
        let scratch = App::xml("com.example.scratch", "");
        let configuration = scratch.root.join("host");
        let home = scratch.root.join("home");
        assert_eq!(
            configured_service_socket_path(&home, &configuration).unwrap(),
            None
        );
        let app = configuration.join("computer-use").join(name);
        fs::create_dir_all(app.join("Contents")).unwrap();
        fs::write(app.join("Contents/Info.plist"),App::plist("com.aex.computeruse","<key>CUAApplicationGroupIdentifier</key><string>KS98C89L5H.owned.endpoint</string>")).unwrap();
        assert_eq!(
            configured_service_socket_path(&home, &configuration).unwrap(),
            Some(
                home.join(
                    "Library/Group Containers/KS98C89L5H.owned.endpoint/IPC/computeruse.sock"
                )
            )
        );
        for (index, id) in [
            "com.aex.computeruse.client",
            "com.example.unrelated",
            "com.example.other.CUAService",
        ]
        .iter()
        .enumerate()
        {
            let other = configuration.join(format!("other-{index}"));
            let app = other.join("computer-use").join(name);
            fs::create_dir_all(app.join("Contents")).unwrap();
            fs::write(app.join("Contents/Info.plist"),App::plist(id,"<key>CUAApplicationGroupIdentifier</key><string>KS98C89L5H.owned.endpoint</string>")).unwrap();
            assert_eq!(configured_service_socket_path(&home, &other).unwrap(), None);
        }
    }
}

#[test]
fn disabled_preferred_service_does_not_fall_through_to_another_candidate() {
    let scratch = App::xml("com.example.scratch", "");
    let configuration = scratch.root.join("host");
    let home = scratch.root.join("home");
    for (name, group) in [
        ("AexComputerUseService.app", ""),
        ("Aex Computer Use.app", "KS98C89L5H.other"),
    ] {
        let app = configuration.join("computer-use").join(name);
        fs::create_dir_all(app.join("Contents")).unwrap();
        fs::write(app.join("Contents/Info.plist"),format!("<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.aex.computeruse</string><key>CUAApplicationGroupIdentifier</key><string>{group}</string></dict></plist>")).unwrap();
    }
    assert!(
        crate::service_endpoint::configured_service_socket_path(&home, &configuration).is_err()
    );
}
