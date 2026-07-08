#!/usr/bin/env python3
import argparse
import json
import os
import sys
import urllib.request
from typing import Dict, List


def extract_name(url: str) -> str:
    """Extracts the app name from a Git URL or just returns the name."""
    if not url:
        return ""
    # Normalize first
    name = url.strip().lower()
    if name.endswith(".git"):
        name = name[:-4]
    if name.endswith("/"):
        name = name[:-1]
    # If it's a URL, get the last component
    if "/" in name:
        name = name.split("/")[-1]
    return name


def get_repos_from_org(org: str) -> List[str]:
    """Fetches all repository clone URLs from a GitHub organization with basic error handling."""
    repos = []
    if not org:
        return repos

    page = 1
    while True:
        url = f"https://api.github.com/orgs/{org}/repos?page={page}&per_page=100"
        try:
            headers = {"Accept": "application/vnd.github.v3+json"}
            # Use GITHUB_TOKEN or GH_BUILD_KEY for authentication
            token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_BUILD_KEY")
            if token:
                headers["Authorization"] = f"token {token}"

            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req) as response:
                if response.status != 200:
                    break
                data = json.loads(response.read().decode())
                if not data:
                    break
                for repo in data:
                    # Filter for active Frappe-like repositories (primitive check)
                    if not repo["archived"] and not repo["disabled"]:
                        repos.append(repo["clone_url"])
                page += 1
        except Exception as e:
            print(f"Error fetching repos from org {org} (Page {page}): {e}", file=sys.stderr)
            break
    return repos


def main():
    parser = argparse.ArgumentParser(description="Discover and list Frappe app URLs uniquely.")
    parser.add_argument("--org", help="GitHub Organization to scan")
    parser.add_argument("--apps", help="Space-separated list of Git URLs or app names")

    args = parser.parse_args()

    unique_apps: Dict[str, str] = {}

    def process_app(app_input: str):
        if not app_input:
            return
        name = extract_name(app_input)
        if not name:
            return

        # Determine if it's a URL
        is_url = "/" in app_input or "github.com" in app_input or app_input.startswith(("http", "git@"))

        # Favor URLs over simple names if we encounter both
        if name not in unique_apps or is_url:
            unique_apps[name] = app_input

    # 1. Process Organization first (if provided)
    if args.org:
        for repo_url in get_repos_from_org(args.org):
            process_app(repo_url)

    # 2. Process Manual List (overrides/augments org)
    if args.apps:
        for app in args.apps.split():
            process_app(app)

    # Final output: space-separated list of unique strings (name#url or name)
    if unique_apps:
        output_items = []
        for name, original in unique_apps.items():
            if "/" in original or "github.com" in original or original.startswith(("http", "git@")):
                output_items.append(f"{name}#{original}")
            else:
                output_items.append(name)
        print(" ".join(output_items))


if __name__ == "__main__":
    main()
