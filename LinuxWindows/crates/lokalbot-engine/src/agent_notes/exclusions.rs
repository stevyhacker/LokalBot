//! The person's project-folder exclusions, applied to notes
//! (`AgentMemoryExclusions`). A note about a folder inside an excluded one
//! never leaves the reader.

use crate::coding_agents::text;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Exclusions {
    /// Standardized absolute folder paths, with `/` separators.
    folders: Vec<String>,
    home: Option<String>,
}

impl Exclusions {
    pub fn new(rules: &[String], home: Option<&str>) -> Self {
        let folders = rules
            .iter()
            .map(|rule| text::standardized_path(rule.trim(), home))
            .filter(|folder| !folder.is_empty() && folder != "/")
            .collect();
        Self {
            folders,
            home: home.map(str::to_string),
        }
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.folders.is_empty()
    }

    pub fn excludes_working_directory(&self, working_directory: Option<&str>) -> bool {
        let Some(directory) = working_directory else {
            return false;
        };
        let path = text::standardized_path(directory, self.home.as_deref());
        self.folders
            .iter()
            .any(|folder| text::is_inside(&path, folder))
    }

    /// Claude Code names a project folder after its working directory with
    /// every character that is not an ASCII letter or digit turned into "-".
    /// That loses which dashes were separators, so a sibling such as `app-old`
    /// reads as inside `app` and is left out too: the safe direction.
    pub fn excludes_claude_project(&self, slug: &str) -> bool {
        self.folders.iter().any(|folder| {
            let excluded = claude_project_slug(folder);
            // Windows paths don't care about case, and a drive letter is
            // written either way.
            let (slug, excluded) = if text::is_windows_path(folder) {
                (slug.to_ascii_lowercase(), excluded.to_ascii_lowercase())
            } else {
                (slug.to_string(), excluded)
            };
            slug.strip_prefix(&excluded)
                .is_some_and(|rest| rest.is_empty() || rest.starts_with('-'))
        })
    }

    /// Whether `text` (a heading or a header line) names an excluded folder.
    pub fn mentions_excluded_folder(&self, text: &str) -> bool {
        self.folders.iter().any(|folder| {
            if !text::is_windows_path(folder) {
                return mentions(text, folder);
            }
            // A Windows folder is written with either separator, in any case.
            let lowered = text.to_ascii_lowercase();
            let folder = folder.to_ascii_lowercase();
            mentions(&lowered, &folder) || mentions(&lowered, &folder.replace('/', "\\"))
        })
    }
}

/// `folder` occurs in `text` as the folder itself or something inside it, not
/// as a sibling whose name merely starts the same (`app-old`, `app.bak`).
fn mentions(text: &str, folder: &str) -> bool {
    let mut from = 0;
    while let Some(found) = text[from..].find(folder) {
        let end = from + found + folder.len();
        let mut rest = text[end..].chars();
        let continues_name = match rest.next() {
            None => false,
            Some('.') => rest.next().is_some_and(char::is_alphanumeric),
            Some(next) => next.is_alphanumeric() || next == '-' || next == '_',
        };
        if !continues_name {
            return true;
        }
        from = end;
    }
    false
}

/// The name Claude Code gives a working directory's project folder. A Windows
/// path gives the same name with either separator: `C:\Code\app` and
/// `C:/Code/app` are both `C--Code-app`.
pub fn claude_project_slug(path: &str) -> String {
    path.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn excluding(folders: &[&str]) -> Exclusions {
        let rules: Vec<String> = folders.iter().map(|folder| folder.to_string()).collect();
        Exclusions::new(&rules, Some("/Users/me"))
    }

    #[test]
    fn folder_mentions_match_the_folder_and_its_contents_but_not_siblings() {
        let exclusions = excluding(&["/Users/me/GitHub/app/"]);

        assert!(exclusions.mentions_excluded_folder("Task Group: /Users/me/GitHub/app release"));
        assert!(exclusions.mentions_excluded_folder("/Users/me/GitHub/app/tools"));
        assert!(exclusions.mentions_excluded_folder("worked in /Users/me/GitHub/app."));
        assert!(!exclusions.mentions_excluded_folder("/Users/me/GitHub/app-old"));
        assert!(!exclusions.mentions_excluded_folder("/Users/me/GitHub/app.bak"));
        assert!(exclusions.excludes_working_directory(Some("/Users/me/GitHub/app/x")));
        assert!(!exclusions.excludes_working_directory(Some("/Users/me/GitHub/application")));
        assert!(!exclusions.excludes_working_directory(None));
        assert!(excluding(&["/", "  "]).is_empty());
    }

    #[test]
    fn a_home_relative_rule_covers_the_folder_under_home() {
        let exclusions = excluding(&[" ~/Secret "]);
        assert!(exclusions.excludes_working_directory(Some("/Users/me/Secret/plans")));
        assert!(exclusions.excludes_claude_project("-Users-me-Secret"));
        assert!(exclusions.excludes_claude_project("-Users-me-Secret-plans"));
        assert!(!exclusions.excludes_claude_project("-Users-me-Secrets"));
        assert!(!exclusions.excludes_claude_project("-Users-me-Open"));
    }

    #[test]
    fn windows_folders_match_either_separator_and_any_case() {
        assert_eq!(
            claude_project_slug(r"C:\Users\me\Code\app"),
            "C--Users-me-Code-app"
        );
        assert_eq!(
            claude_project_slug("/Users/me/GitHub/app"),
            "-Users-me-GitHub-app"
        );
        assert_eq!(claude_project_slug("/home/mé/app_1"), "-home-m--app-1");

        let rules = vec![r"C:\Users\me\Code\secret".to_string()];
        let exclusions = Exclusions::new(&rules, Some(r"C:\Users\me"));
        assert!(exclusions.excludes_working_directory(Some(r"c:\users\me\code\secret\tools")));
        assert!(!exclusions.excludes_working_directory(Some(r"C:\Users\me\Code\secrets")));
        assert!(exclusions.excludes_claude_project("C--Users-me-Code-secret"));
        assert!(exclusions.excludes_claude_project("c--Users-me-Code-secret-tools"));
        assert!(!exclusions.excludes_claude_project("C--Users-me-Code-open"));
        assert!(exclusions.mentions_excluded_folder(r"Task Group: C:\Users\me\Code\secret builds"));
        assert!(exclusions.mentions_excluded_folder("C:/Users/me/Code/secret/tools"));
        assert!(!exclusions.mentions_excluded_folder(r"C:\Users\me\Code\secret-old"));

        let home_rule = Exclusions::new(&[r"~\Code\secret".to_string()], Some(r"C:\Users\me"));
        assert!(home_rule.excludes_working_directory(Some(r"C:\Users\me\Code\secret")));
    }
}
