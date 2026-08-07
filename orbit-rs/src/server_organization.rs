use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ServerFolder {
    pub id: String,
    pub name: String,
    pub normalized_name: String,
    pub parent_id: Option<String>,
    pub sort_order: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ServerTag {
    pub id: String,
    pub name: String,
    pub normalized_name: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ServerTagLink {
    pub server_id: String,
    pub tag_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerOrganizationSnapshot {
    pub folders: Vec<ServerFolder>,
    pub tags: Vec<ServerTag>,
    pub tag_links: Vec<ServerTagLink>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FolderInput {
    pub name: String,
    pub parent_id: Option<String>,
    pub sort_order: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FolderMoveInput {
    pub parent_id: Option<String>,
    pub sort_order: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FolderDeleteInput {
    pub destination_folder_id: Option<String>,
    pub delete_servers: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerTagsInput {
    pub tag_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerMoveInput {
    pub folder_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerPinInput {
    pub is_pinned: bool,
    pub pin_order: Option<i64>,
}

pub fn normalize_name(name: &str) -> Result<String> {
    let normalized = name.trim().to_lowercase();
    if normalized.is_empty() {
        bail!("名称不能为空");
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::{normalize_name, FolderInput};
    use crate::db::Database;
    use crate::models::ServerInput;

    fn test_db() -> Database {
        Database::new(":memory:").unwrap()
    }

    fn seeded_server_db() -> Database {
        let db = test_db();
        db.add_server(&ServerInput {
            name: "server-1".into(),
            host: "10.0.0.1".into(),
            port: None,
            group_name: None,
            auth_type: None,
            username: "root".into(),
            password: None,
            private_key: None,
            key_source: None,
            key_file_path: None,
            key_passphrase: None,
            credential_group_id: None,
            jump_server_id: None,
            folder_id: None,
        })
        .unwrap();
        db
    }

    fn only_server_id(db: &Database) -> String {
        db.list_servers().unwrap().pop().unwrap().id
    }

    fn folder(name: &str, parent_id: Option<&str>) -> FolderInput {
        FolderInput {
            name: name.into(),
            parent_id: parent_id.map(str::to_owned),
            sort_order: None,
        }
    }

    #[test]
    fn normalized_names_trim_and_fold_case() {
        assert_eq!(normalize_name("  Production  ").unwrap(), "production");
        assert!(normalize_name("   ").is_err());
    }

    #[test]
    fn rejects_fourth_level_and_descendant_move() {
        let db = test_db();
        let a = db.create_server_folder(&folder("a", None)).unwrap();
        let b = db.create_server_folder(&folder("b", Some(&a.id))).unwrap();
        let c = db.create_server_folder(&folder("c", Some(&b.id))).unwrap();

        assert!(db.create_server_folder(&folder("d", Some(&c.id))).is_err());
        assert!(db.move_server_folder(&a.id, Some(&c.id), 0).is_err());
    }

    #[test]
    fn rejects_duplicate_sibling_names_after_normalization() {
        let db = test_db();
        let parent = db.create_server_folder(&folder("parent", None)).unwrap();
        db.create_server_folder(&folder("Production", Some(&parent.id)))
            .unwrap();

        assert!(db
            .create_server_folder(&folder(" production ", Some(&parent.id)))
            .is_err());
    }

    #[test]
    fn nonempty_delete_moves_all_subtree_servers_atomically() {
        let db = seeded_server_db();
        let server_id = only_server_id(&db);
        let source = db.create_server_folder(&folder("source", None)).unwrap();
        let child = db
            .create_server_folder(&folder("child", Some(&source.id)))
            .unwrap();
        let target = db.create_server_folder(&folder("target", None)).unwrap();
        db.move_server(&server_id, Some(&child.id)).unwrap();

        db.delete_server_folder(&source.id, Some(&target.id), false)
            .unwrap();

        assert_eq!(
            db.get_server(&server_id).unwrap().folder_id,
            Some(target.id)
        );
        assert!(db
            .server_organization()
            .unwrap()
            .folders
            .iter()
            .all(|f| f.id != source.id));
        assert!(db
            .server_organization()
            .unwrap()
            .folders
            .iter()
            .all(|f| f.id != child.id));
    }

    #[test]
    fn nonempty_delete_requires_one_explicit_content_disposition() {
        let db = seeded_server_db();
        let server_id = only_server_id(&db);
        let source = db.create_server_folder(&folder("source", None)).unwrap();
        db.move_server(&server_id, Some(&source.id)).unwrap();

        assert!(db.delete_server_folder(&source.id, None, false).is_err());
        assert!(db.get_server(&server_id).is_ok());
        assert!(db
            .server_organization()
            .unwrap()
            .folders
            .iter()
            .any(|f| f.id == source.id));
    }

    #[test]
    fn tags_are_global_and_server_links_are_replaced() {
        let db = seeded_server_db();
        let server_id = only_server_id(&db);
        let prod = db.create_server_tag("Prod").unwrap();
        let staging = db.create_server_tag("Staging").unwrap();
        assert!(db.create_server_tag(" prod ").is_err());

        db.set_server_tags(&server_id, &[prod.id.clone()]).unwrap();
        db.set_server_tags(&server_id, &[staging.id.clone()])
            .unwrap();

        assert_eq!(db.server_tag_ids(&server_id).unwrap(), vec![staging.id]);
    }

    #[test]
    fn moving_to_root_and_unpinning_clear_explicit_organization_state() {
        let db = seeded_server_db();
        let server_id = only_server_id(&db);
        let folder = db.create_server_folder(&folder("source", None)).unwrap();
        db.move_server(&server_id, Some(&folder.id)).unwrap();
        db.move_server(&server_id, None).unwrap();
        let pinned = db.set_server_pin(&server_id, true, None).unwrap();
        let unpinned = db.set_server_pin(&server_id, false, Some(99)).unwrap();

        assert_eq!(db.get_server(&server_id).unwrap().folder_id, None);
        assert_eq!(pinned.pin_order, Some(1));
        assert!(!unpinned.is_pinned);
        assert_eq!(unpinned.pin_order, None);
    }
}
