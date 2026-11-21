use crate::coding_agents::text;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Exclusions {
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

    pub fn excludes_claude_project(&self, slug: &str) -> bool {
        self.folders.iter().any(|folder| {
            let excluded = claude_project_slug(folder);
            let (slug, excluded) = if text::is_windows_path(folder) {
                (slug.to_ascii_lowercase(), excluded.to_ascii_lowercase())
            } else {
                (slug.to_string(), excluded)
            };
            slug.strip_prefix(&excluded)
                .is_some_and(|rest| rest.is_empty() || rest.starts_with('-'))
        })
    }

    pub fn mentions_excluded_folder(&self, text: &str) -> bool {
        self.folders.iter().any(|folder| {
            if !text::is_windows_path(folder) {
                return mentions(text, folder);
            }
            let lowered = text.to_ascii_lowercase();
            let folder = folder.to_ascii_lowercase();
            mentions(&lowered, &folder) || mentions(&lowered, &folder.replace('/', "\\"))
        })
    }
}

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
