//! The package that installed this copy, so an update it cannot install
//! itself is offered the way that package updates.
//!
//! The package databases answer directly: `pacman -Qqo`, `dpkg-query -S`
//! and `rpm -qf` on the executable. A copy no package lists (install.sh, an
//! extracted archive, a folder under `/opt`) gets no answer. Linux only.

use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::Version;

/// The name of the release's own `.deb`, `.rpm` and Arch packages
/// (`scripts/package-linux-distros.sh`). They are installed from a
/// downloaded file. Once the repository key is committed, the `.deb` and
/// `.rpm` also add LokalBot's apt or dnf repository ([`repository_file`]),
/// and from then on the package manager fetches the next version; the Arch
/// package never has one. Other names, such as the AUR's `lokalbot-bin`,
/// come from a repository.
pub const RELEASE_PACKAGE: &str = "lokalbot";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Manager {
    Pacman,
    Dpkg,
    Rpm,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Package {
    pub manager: Manager,
    pub name: String,
    /// LokalBot's own repository is set up and enabled for this manager.
    pub repository: bool,
}

impl Package {
    /// One of the release's own packages with no repository to update it:
    /// installed from a downloaded file, so the next one is too.
    pub fn from_release(&self) -> bool {
        self.name == RELEASE_PACKAGE && !self.repository
    }

    /// Updates a package from its repository.
    pub fn update_command(&self) -> &'static str {
        match self.manager {
            // Arch users run an AUR helper; yay also updates repository packages.
            Manager::Pacman => "yay -Syu",
            Manager::Dpkg => "sudo apt upgrade",
            Manager::Rpm => "sudo dnf upgrade",
        }
    }

    /// Installs `version`'s release package of this format, downloaded into
    /// the current folder. The file names are package-linux-distros.sh's.
    pub fn install_command(&self, version: Version) -> String {
        match self.manager {
            Manager::Pacman => {
                format!("sudo pacman -U ./LokalBot-{version}-linux-x86_64.pkg.tar.zst")
            }
            Manager::Dpkg => format!("sudo apt install ./LokalBot-{version}-linux-amd64.deb"),
            Manager::Rpm => format!("sudo dnf install ./LokalBot-{version}-linux-x86_64.rpm"),
        }
    }
}

/// The repository file the release's `.deb` (deb822) or `.rpm` installs
/// for LokalBot's apt or dnf repository (`packaging/linux`).
pub fn repository_file(manager: Manager) -> Option<&'static Path> {
    match manager {
        Manager::Dpkg => Some(Path::new("/etc/apt/sources.list.d/lokalbot.sources")),
        Manager::Rpm => Some(Path::new("/etc/yum.repos.d/lokalbot.repo")),
        Manager::Pacman => None,
    }
}

/// The package that installed `executable`, or `None` when no package
/// database lists it. Starts the package tools and reads the repository
/// file, so call it off the UI thread.
pub fn owner(executable: &Path) -> Option<Package> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    owner_with(
        executable,
        &|program, args| {
            let output = Command::new(program)
                .args(args)
                .env("LC_ALL", "C")
                .stdin(Stdio::null())
                .stderr(Stdio::null())
                .output()
                .ok()?;
            output
                .status
                .success()
                .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
        },
        &|path| std::fs::read_to_string(path).ok(),
    )
}

/// [`owner`] with `run` starting a package tool and returning what it
/// printed when it succeeded, and `read` reading a file.
fn owner_with(
    executable: &Path,
    run: &dyn Fn(&str, &[&OsStr]) -> Option<String>,
    read: &dyn Fn(&Path) -> Option<String>,
) -> Option<Package> {
    let path = executable.as_os_str();
    // A system can have another distribution's tools (dpkg on Arch, to build
    // .debs); only the database that lists the file answers.
    let queries: [(Manager, &str, &[&OsStr]); 3] = [
        (Manager::Pacman, "pacman", &["-Qqo".as_ref(), path]),
        (Manager::Dpkg, "dpkg-query", &["-S".as_ref(), path]),
        (
            Manager::Rpm,
            "rpm",
            &[
                "-qf".as_ref(),
                "--queryformat".as_ref(),
                "%{NAME}\\n".as_ref(),
                path,
            ],
        ),
    ];
    queries.into_iter().find_map(|(manager, program, args)| {
        let name = parse(manager, &run(program, args)?)?;
        let repository = repository_file(manager)
            .and_then(read)
            .is_some_and(|text| enabled(&text));
        Some(Package {
            manager,
            name,
            repository,
        })
    })
}

/// Whether a repository file leaves its repository on: no `Enabled: no`
/// (deb822) or `enabled=0` (dnf) line.
fn enabled(text: &str) -> bool {
    !text.lines().any(|line| {
        let line = line.trim();
        if line.starts_with('#') {
            return false;
        }
        let Some((key, value)) = line.split_once([':', '=']) else {
            return false;
        };
        key.trim().eq_ignore_ascii_case("enabled")
            && ["no", "false", "off", "0"]
                .iter()
                .any(|off| value.trim().eq_ignore_ascii_case(off))
    })
}

/// The package name in a tool's answer.
fn parse(manager: Manager, output: &str) -> Option<String> {
    let mut lines = output.lines().map(str::trim).filter(|l| !l.is_empty());
    let name = match manager {
        Manager::Pacman | Manager::Rpm => lines.next()?,
        // `lokalbot: /usr/bin/lokalbot`, `libc6:amd64: /usr/lib/…` or
        // `a, b: /path`, after any `diversion by …` lines.
        Manager::Dpkg => lines
            .filter(|l| !l.starts_with("diversion by "))
            .find_map(|l| l.split_once(": /"))?
            .0
            .split(", ")
            .next()?
            .split(':')
            .next()?,
    };
    let valid = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "@._+-".contains(c));
    valid.then(|| name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn lookup(answers: &[(&str, &str)]) -> (Option<Package>, Vec<String>) {
        lookup_with_files(answers, &[])
    }

    /// [`owner_with`] with tool answers and the files that exist.
    fn lookup_with_files(
        answers: &[(&str, &str)],
        files: &[(&str, &str)],
    ) -> (Option<Package>, Vec<String>) {
        let asked = RefCell::new(Vec::new());
        let package = owner_with(
            Path::new("/usr/bin/lokalbot"),
            &|program, args| {
                let args: Vec<_> = args.iter().map(|a| a.to_string_lossy()).collect();
                asked
                    .borrow_mut()
                    .push(format!("{program} {}", args.join(" ")));
                answers
                    .iter()
                    .find(|(tool, _)| *tool == program)
                    .map(|(_, out)| out.to_string())
            },
            &|path| {
                files
                    .iter()
                    .find(|(file, _)| Path::new(file) == path)
                    .map(|(_, text)| text.to_string())
            },
        );
        (package, asked.into_inner())
    }

    #[test]
    fn the_database_that_lists_the_file_names_its_package() {
        let (package, asked) = lookup(&[("pacman", "lokalbot-bin\n")]);
        assert_eq!(
            package,
            Some(Package {
                manager: Manager::Pacman,
                name: "lokalbot-bin".into(),
                repository: false
            })
        );
        assert_eq!(asked, ["pacman -Qqo /usr/bin/lokalbot"]);

        let (package, asked) = lookup(&[("dpkg-query", "lokalbot: /usr/bin/lokalbot\n")]);
        assert_eq!(
            package,
            Some(Package {
                manager: Manager::Dpkg,
                name: "lokalbot".into(),
                repository: false
            })
        );
        assert_eq!(
            asked,
            [
                "pacman -Qqo /usr/bin/lokalbot",
                "dpkg-query -S /usr/bin/lokalbot"
            ]
        );

        let (package, asked) = lookup(&[("rpm", "lokalbot\n")]);
        assert_eq!(package.map(|p| p.manager), Some(Manager::Rpm));
        assert_eq!(
            asked.last().unwrap(),
            "rpm -qf --queryformat %{NAME}\\n /usr/bin/lokalbot"
        );
    }

    #[test]
    fn release_packages_with_the_repository_file_update_from_it() {
        const SOURCES: &str = "/etc/apt/sources.list.d/lokalbot.sources";
        const REPO: &str = "/etc/yum.repos.d/lokalbot.repo";
        let sources = include_str!("../../../packaging/linux/lokalbot.sources");
        let repo = include_str!("../../../packaging/linux/lokalbot.repo");
        let deb = [("dpkg-query", "lokalbot: /usr/bin/lokalbot\n")];
        let rpm = [("rpm", "lokalbot\n")];

        let package = lookup_with_files(&deb, &[(SOURCES, sources)]).0.unwrap();
        assert!(package.repository && !package.from_release());
        let package = lookup_with_files(&rpm, &[(REPO, repo)]).0.unwrap();
        assert!(package.repository && !package.from_release());

        // Installed before the repository existed, or with it turned off.
        assert!(lookup(&deb).0.unwrap().from_release());
        let off = format!("{sources}Enabled: no\n");
        assert!(
            lookup_with_files(&deb, &[(SOURCES, &off)])
                .0
                .unwrap()
                .from_release()
        );
        let off = repo.replace("enabled=1", "enabled=0");
        assert!(
            lookup_with_files(&rpm, &[(REPO, &off)])
                .0
                .unwrap()
                .from_release()
        );
        // The other manager's file says nothing about this package.
        assert!(
            lookup_with_files(&deb, &[(REPO, repo)])
                .0
                .unwrap()
                .from_release()
        );
        // The Arch package never has a repository.
        let arch = lookup_with_files(
            &[("pacman", "lokalbot\n")],
            &[(SOURCES, sources), (REPO, repo)],
        );
        assert!(arch.0.unwrap().from_release());
    }

    #[test]
    fn no_package_and_odd_answers_are_no_owner() {
        assert_eq!(lookup(&[]).0, None);
        assert_eq!(lookup(&[("pacman", "")]).0, None);
        assert_eq!(lookup(&[("pacman", "error: no package owns it")]).0, None);
        assert_eq!(
            lookup(&[("dpkg-query", "dpkg-query: no path found")]).0,
            None
        );
    }

    #[test]
    fn dpkg_answers_name_the_first_package() {
        let name = |out| parse(Manager::Dpkg, out);
        assert_eq!(
            name("lokalbot: /usr/bin/lokalbot").as_deref(),
            Some("lokalbot")
        );
        assert_eq!(name("libc6:amd64: /usr/lib/x").as_deref(), Some("libc6"));
        assert_eq!(
            name("lokalbot, other: /usr/bin/lokalbot").as_deref(),
            Some("lokalbot")
        );
        assert_eq!(
            name(
                "diversion by other from: /usr/bin/lokalbot\n\
                 diversion by other to: /usr/bin/lokalbot.real\n\
                 lokalbot: /usr/bin/lokalbot"
            )
            .as_deref(),
            Some("lokalbot")
        );
    }

    #[test]
    fn commands_match_the_release_packages() {
        let version = Version::new(0, 11, 1);
        let package = |manager, name: &str| Package {
            manager,
            name: name.into(),
            repository: false,
        };
        assert!(package(Manager::Dpkg, "lokalbot").from_release());
        assert!(!package(Manager::Pacman, "lokalbot-bin").from_release());
        assert_eq!(
            package(Manager::Dpkg, "lokalbot").install_command(version),
            "sudo apt install ./LokalBot-0.11.1-linux-amd64.deb"
        );
        assert_eq!(
            package(Manager::Rpm, "lokalbot").install_command(version),
            "sudo dnf install ./LokalBot-0.11.1-linux-x86_64.rpm"
        );
        assert_eq!(
            package(Manager::Pacman, "lokalbot").install_command(version),
            "sudo pacman -U ./LokalBot-0.11.1-linux-x86_64.pkg.tar.zst"
        );
        assert_eq!(
            package(Manager::Pacman, "lokalbot-bin").update_command(),
            "yay -Syu"
        );
    }
}
