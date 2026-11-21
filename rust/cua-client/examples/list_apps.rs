use cua_client::{Client, Result};

fn main() -> Result<()> {
    let mut cua = Client::connect()?;
    for app in cua.list_apps()? {
        println!("{} ({})", app.display_name, app.bundle_identifier);
    }
    Ok(())
}
