#!/usr/bin/env python3
import sys, json, requests
def main():
    q = json.load(sys.stdin)
    path = q["path"]
    url  = q.get("url", "https://factory.talos.dev/schematics")
    with open(path, "rb") as f:
        r = requests.post(url, data=f.read(), timeout=60)
    r.raise_for_status()
    print(json.dumps({"id": r.json()["id"]}))
if __name__ == "__main__":
    main()