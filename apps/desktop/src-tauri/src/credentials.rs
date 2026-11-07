use keyring_core::{api::CredentialStoreApi, Entry, Result};

pub(crate) fn entry(service: &str, user: &str) -> Result<Entry> {
    // Keyring 4's convenience wrapper permanently caches initialization errors.
    // Create a fresh store for each operation, also recovering stale D-Bus sessions.
    #[cfg(target_os = "macos")]
    let store = apple_native_keyring_store::keychain::Store::new()?;
    #[cfg(windows)]
    let store = windows_native_keyring_store::Store::new()?;
    #[cfg(target_os = "linux")]
    let store = zbus_secret_service_keyring_store::Store::new()?;
    store.build(service, user, None)
}
