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

pub fn normalize_name(name: &str) -> Result<String> {
    let normalized = name.trim().to_lowercase();
    if normalized.is_empty() {
        bail!("名称不能为空");
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::normalize_name;

    #[test]
    fn normalized_names_trim_and_fold_case() {
        assert_eq!(normalize_name("  Production  ").unwrap(), "production");
        assert!(normalize_name("   ").is_err());
    }
}
