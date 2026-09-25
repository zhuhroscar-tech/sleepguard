import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class RepositoryContractTests(unittest.TestCase):
    def test_required_project_files_exist(self):
        for relative in [
            "README.md",
            "README.zh-CN.md",
            "CHANGELOG.md",
            "LICENSE",
            "Package.swift",
            "scripts/build_app.sh",
            "docs/REFERENCE.md",
            ".github/workflows/build.yml",
        ]:
            with self.subTest(path=relative):
                self.assertTrue((ROOT / relative).is_file(), f"missing {relative}")

    def test_readme_local_links_and_assets_exist(self):
        for readme_name in ["README.md", "README.zh-CN.md", "docs/REFERENCE.md"]:
            text = (ROOT / readme_name).read_text(encoding="utf-8")
            base = (ROOT / readme_name).parent
            for target in re.findall(r"\[[^\]]+\]\((?!https?://|mailto:|#)([^)]+)\)", text):
                path_part = target.split("#", 1)[0]
                if not path_part:
                    continue
                with self.subTest(readme=readme_name, target=target):
                    self.assertTrue((base / path_part).exists(), f"broken local link {target}")
            for target in re.findall(r"!\[[^\]]*\]\((?!https?://)([^)]+)\)", text):
                path_part = target.split("#", 1)[0]
                with self.subTest(readme=readme_name, asset=target):
                    self.assertTrue((base / path_part).is_file(), f"missing local asset {target}")

    def test_package_declares_public_products_and_shared_core(self):
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        for product in ["SleepGuardCore", "sleepguard", "SleepGuardMenuBar", "sleepguard-tests"]:
            with self.subTest(product=product):
                self.assertIn(f'name: "{product}"', package)
        self.assertIn('.executableTarget(name: "sleepguard", dependencies: ["SleepGuardCore"])', package)
        self.assertIn('.executableTarget(name: "SleepGuardMenuBar", dependencies: ["SleepGuardCore"])', package)
        self.assertIn('.executableTarget(name: "sleepguard-tests", dependencies: ["SleepGuardCore"])', package)

    def test_ci_runs_core_tests_and_packaging_checks(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        for required in [
            "xcrun swift-format lint --recursive --strict Sources Package.swift",
            "swift run sleepguard-tests",
            "RUN_LIVE_TESTS: \"1\"",
            "swift build -c release -Xswiftc -warnings-as-errors",
            "bash scripts/build_app.sh",
            "codesign --verify --deep --strict",
            "ditto -x -k SleepGuard.zip extracted",
            "python3 -m unittest discover -s Tests/RepositoryContractTests -v",
        ]:
            with self.subTest(required=required):
                self.assertIn(required, workflow)

    def test_ci_runs_for_release_tags(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
        self.assertIn("tags: [\"v*\"]", workflow)

    def test_release_claims_remain_local_and_unsigned(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        zh_readme = (ROOT / "README.zh-CN.md").read_text(encoding="utf-8")
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        build_script = (ROOT / "scripts/build_app.sh").read_text(encoding="utf-8")
        self.assertIn("Development prototype—not a signed or notarized release", readme)
        self.assertIn("开发原型，不是经过正式签名或公证的发行版", zh_readme)
        self.assertIn("not Developer ID signed or notarized app distributions", changelog)
        self.assertIn("NOT Developer ID signing and NOT notarization", build_script)
        self.assertIn('codesign --force --sign - --timestamp=none "$APP"', build_script)

    def test_changelog_tracks_latest_release(self):
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertIn("## v0.2.2 — 2026-09-25", changelog)
        self.assertIn("## v0.2.1 — 2026-09-24", changelog)
        self.assertIn("## v0.2.0 — 2026-09-23", changelog)
        self.assertIn("SleepGuard.zip", changelog)
        self.assertIn("ad-hoc signed local build artifact", changelog)


if __name__ == "__main__":
    unittest.main()
