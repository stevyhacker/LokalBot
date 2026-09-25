"""Static regression checks for the release signing-authority boundary."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")


def step(name: str) -> str:
    marker = f"      - name: {name}\n"
    start = WORKFLOW.index(marker)
    end = WORKFLOW.find("\n      - name: ", start + len(marker))
    return WORKFLOW[start:end if end >= 0 else None]


class ReleaseSigningBoundaryTests(unittest.TestCase):
    def test_build_and_native_validation_finish_before_developer_id_import(self):
        archive = step("Archive release payload without Developer ID authority")
        signing = step("Export and seal app with short-lived Developer ID authority")
        self.assertLess(WORKFLOW.index("Fetch llama.cpp vendor"), WORKFLOW.index(signing))
        self.assertLess(WORKFLOW.index("Fetch sherpa-onnx vendor"), WORKFLOW.index(signing))
        self.assertLess(WORKFLOW.index("Resolve Swift packages before unlocking signing authority"),
                        WORKFLOW.index(signing))
        self.assertLess(WORKFLOW.index(archive), WORKFLOW.index(signing))
        self.assertIn('CODE_SIGN_IDENTITY="-"', archive)
        self.assertNotIn("MACOS_CERTIFICATE", archive)
        self.assertNotIn("Developer ID Application", archive)

    def test_app_keychain_is_destroyed_before_validation_or_other_tools(self):
        signing = step("Export and seal app with short-lived Developer ID authority")
        self.assertIn("xcodebuild -exportArchive", signing)
        self.assertNotIn("fetch-sherpa", signing)
        self.assertNotIn("fetch-llama", signing)
        final_sign = signing.rindex("build/export/LokalBot.app")
        cleanup = signing.rindex("cleanup_signing_authority")
        self.assertGreater(cleanup, final_sign)
        verify = WORKFLOW.index("      - name: Verify exported signatures and secure timestamps")
        self.assertGreater(verify, WORKFLOW.index(signing) + cleanup)

    def test_dmg_keychain_is_destroyed_before_notarization(self):
        signing = step("Sign, notarize + staple the DMG")
        signature = signing.index("--timestamp build/LokalBot.dmg")
        cleanup = signing.rindex("cleanup_signing_authority")
        verification = signing.index("codesign --verify")
        notarization = signing.index("notarytool submit")
        self.assertLess(signature, cleanup)
        self.assertLess(cleanup, verification)
        self.assertLess(cleanup, notarization)

    def test_signing_keychains_are_searchable_while_codesign_runs(self):
        # codesign finds the identity's private key through the user keychain
        # search list, even with --keychain. Without it the DMG signature fails
        # with "The specified item could not be found in the keychain."
        for name, signature in (
            ("Export and seal app with short-lived Developer ID authority", "xcodebuild -exportArchive"),
            ("Sign, notarize + staple the DMG", "--timestamp build/LokalBot.dmg"),
        ):
            signing = step(name)
            searchable = signing.index('security list-keychains -d user -s "$keychain" login.keychain-db')
            self.assertLess(signing.index("security set-key-partition-list"), searchable, name)
            self.assertLess(searchable, signing.index(signature), name)
            self.assertIn("security list-keychains -d user -s login.keychain-db",
                          signing[signing.index("cleanup_signing_authority() {"):], name)


if __name__ == "__main__":
    unittest.main()
