use std::collections::HashMap;
use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use crate::{models::{CredentialGroupInput, ServerInput}, OrbitApp};

pub(crate) fn export(app: &OrbitApp, path: &str, include_secrets: bool) -> Result<()> {
    let mut servers = serde_json::to_value(app.db.list_servers()?)?;
    let mut groups = serde_json::to_value(app.db.list_credential_groups()?)?;
    if !include_secrets {
        for array in [&mut servers, &mut groups] {
            if let Some(items) = array.as_array_mut() { for item in items { if let Some(object) = item.as_object_mut() { for key in ["password", "private_key", "key_passphrase"] { object.remove(key); } } } }
        }
    }
    let value = json!({"servers":servers,"credential_groups":groups,"organization":app.db.server_organization()?,"exported_at":chrono::Utc::now().to_rfc3339()});
    let destination = std::path::Path::new(path);
    let temporary = destination.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> { std::fs::write(&temporary, serde_json::to_vec_pretty(&value)?)?; std::fs::rename(&temporary, destination)?; Ok(()) })();
    if result.is_err() { let _ = std::fs::remove_file(temporary); }
    result
}

pub(crate) fn import(app: &OrbitApp, path: &str, overwrite: bool) -> Result<usize> {
    let file = std::fs::File::open(path)?;
    if file.metadata()?.len() > 10 * 1024 * 1024 { anyhow::bail!("配置文件超过 10 MB"); }
    let value: Value = serde_json::from_reader(file)?;
    let servers = value["servers"].as_array().ok_or_else(|| anyhow!("配置缺少 servers 数组"))?;
    let groups = value["credential_groups"].as_array().cloned().unwrap_or_default();
    for server in servers { let _: ServerInput = serde_json::from_value(server.clone())?; }
    for group in &groups { let _: CredentialGroupInput = serde_json::from_value(group.clone())?; }
    let mut count = 0;
    let result = (|| -> Result<()> {
        let existing_groups = app.db.list_credential_groups()?;
        let mut group_ids = HashMap::new();
        for group in groups {
            let mut input: CredentialGroupInput = serde_json::from_value(group.clone())?;
            let saved = if let Some(existing) = existing_groups.iter().find(|existing| existing.name == input.name) {
                if overwrite {
                    if input.password.is_none() { input.password = Some(existing.password.clone()); }
                    if input.private_key.is_none() { input.private_key = Some(existing.private_key.clone()); }
                    if input.key_passphrase.is_none() { input.key_passphrase = Some(existing.key_passphrase.clone()); }
                    app.db.update_credential_group(&existing.id, &input)?; count += 1;
                }
                existing.id.clone()
            } else { let added = app.db.add_credential_group(&input)?; count += 1; added.id };
            if let Some(id) = group["id"].as_str() { group_ids.insert(id.to_string(), saved); }
        }
        let existing_org = app.db.server_organization()?;
        let mut folder_ids = HashMap::new();
        let mut folders = value["organization"]["folders"].as_array().cloned().unwrap_or_default();
        while !folders.is_empty() {
            let index = folders.iter().position(|folder| folder["parent_id"].is_null() || folder["parent_id"].as_str().map(|id| folder_ids.contains_key(id)).unwrap_or(false)).ok_or_else(|| anyhow!("目录父子关系无效"))?;
            let folder = folders.remove(index);
            let old_id = folder["id"].as_str().ok_or_else(|| anyhow!("目录缺少 ID"))?;
            let name = folder["name"].as_str().ok_or_else(|| anyhow!("目录缺少名称"))?;
            let parent = folder["parent_id"].as_str().and_then(|id| folder_ids.get(id)).cloned();
            let id = if let Some(existing) = existing_org.folders.iter().find(|existing| existing.name == name && existing.parent_id == parent) { existing.id.clone() } else {
                app.db.create_server_folder(&crate::server_organization::FolderInput { name: name.into(), parent_id: parent, sort_order: folder["sort_order"].as_i64() })?.id
            };
            folder_ids.insert(old_id.to_string(), id);
        }
        let existing_servers = app.db.list_servers()?;
        let mut server_ids = HashMap::new(); let mut changed = Vec::new();
        for server in servers {
            let mut input: ServerInput = serde_json::from_value(server.clone())?;
            input.credential_group_id = input.credential_group_id.as_deref().filter(|id| !id.is_empty()).map(|id| group_ids.get(id).cloned().ok_or_else(|| anyhow!("引用的凭据组不存在"))).transpose()?;
            input.folder_id = input.folder_id.as_deref().and_then(|id| folder_ids.get(id)).cloned();
            input.jump_server_id = Some(String::new());
            let existing = existing_servers.iter().find(|existing| existing.host == input.host && existing.port == input.port.unwrap_or(22));
            let (id, did_change) = if let Some(existing) = existing {
                if overwrite { app.db.update_server(&existing.id, &input)?; count += 1; }
                (existing.id.clone(), overwrite)
            } else { let added = app.db.add_server(&input)?; count += 1; (added.id, true) };
            if let Some(old_id) = server["id"].as_str() { server_ids.insert(old_id.to_string(), id.clone()); }
            if did_change { changed.push((id, server.clone(), input)); }
        }
        for (id, server, mut input) in changed {
            input.jump_server_id = server["jump_server_id"].as_str().filter(|id| !id.is_empty()).map(|id| server_ids.get(id).cloned().ok_or_else(|| anyhow!("引用的跳板机不存在"))).transpose()?;
            app.db.update_server(&id, &input)?;
            if let Some(pinned) = server["is_pinned"].as_bool() { app.db.set_server_pin(&id, pinned, server["pin_order"].as_i64())?; }
        }
        let mut tag_ids = HashMap::new();
        if let Some(tags) = value["organization"]["tags"].as_array() {
            for tag in tags {
                let id = tag["id"].as_str().ok_or_else(|| anyhow!("标签缺少 ID"))?;
                let name = tag["name"].as_str().ok_or_else(|| anyhow!("标签缺少名称"))?;
                let saved = if let Some(existing) = existing_org.tags.iter().find(|existing| existing.name == name) { existing.id.clone() } else { app.db.create_server_tag(name)?.id };
                tag_ids.insert(id.to_string(), saved);
            }
        }
        if let Some(links) = value["organization"]["tag_links"].as_array() {
            let mut mapped: HashMap<String, Vec<String>> = HashMap::new();
            for link in links {
                if let (Some(server), Some(tag)) = (link["server_id"].as_str().and_then(|id| server_ids.get(id)), link["tag_id"].as_str().and_then(|id| tag_ids.get(id))) { mapped.entry(server.clone()).or_default().push(tag.clone()); }
            }
            for (server, tags) in mapped { let mut ids = app.db.server_tag_ids(&server)?; for tag in tags { if !ids.contains(&tag) { ids.push(tag); } } app.db.set_server_tags(&server, &ids)?; }
        }
        Ok(())
    })();
    result.with_context(|| format!("导入未全部完成，已处理 {} 项服务器/凭据组", count))?;
    Ok(count)
}
