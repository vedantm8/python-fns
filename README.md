# python-fns

A lightweight Docker image for running serverless-style Python functions with fnctl. This image is designed to make it easy to deploy and verify function containers on a Linux VM or LXC. For reference, this was created within a [Docker LXC](https://community-scripts.github.io/ProxmoxVE/scripts?id=docker).

## Links
- [Docker Hub Image](https://hub.docker.com/r/vedantm8/python-fns)

## Features
- Preconfigured Python runtime for functions
- Includes `fnctl` for managing functions. 
- Verified via `fn-verify-all`
- Can be pushed to DockerHub and redeployed anywhere

## Prerequisites
- Docker installed and running
- **Tested Environment:** Currently tested only on Linux LXC (Proxmox). Other environments (native Linux, macOS, Windows) have not yet been verified.

## Getting Started

### Pull the image
```
docker pull vedantm8/python-fns:latest
```

### Run the container
```
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /opt/functions:/opt/functions \
  -v /usr/local/bin:/host-bin \
  -e HOST_FUNCTIONS_DIR=/opt/functions \
  -e HOST_BIN_DIR=/host-bin \
  vedantm8/python-fns:latest
```

### Verify functions
Inside the container, run:
```
fn-verify-all
```

## Usage
You can create, test, and manage Python functions directly inside this container.  
Examples:
- Create a new function: `fnctl new hello`
- Call a function: `fnctl call hello`
- View logs: `fnctl logs hello`

All functions are stored under the following path inside the container:  
```
/opt/functions/fn-<name>
```  

Each function resides in its own folder (e.g., `/opt/functions/fn-hello/`).

```
/opt/functions/
  ├── fn-hello/
  │   ├── Dockerfile
  │   ├── main.py
  │   └── requirements.txt
  └── fn-math/
      ├── Dockerfile
      ├── main.py
      └── requirements.txt
```

### Example: create, edit, build, and test a function that uses `requests` library

1. Create a new function: 
```
fnctl new test
```

2. Move into the function directory: 
```
cd /opt/functions/fn-test/
```

3. Add `requests` to the function dependencies:
```
echo 'requests' >> requirements.txt
```

4. Replace the contents of `main.py` with the following example, which exposes a single POST `/invoke` that fetches a URL and returns basic info:
```
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, HttpUrl
import requests

app = FastAPI()

class FetchIn(BaseModel):
    url: HttpUrl

@app.post("/invoke")
def fetch(inp: FetchIn):
    try:
        resp = requests.get(str(inp.url), timeout=10)
    except requests.RequestException as e:
        raise HTTPException(status_code=502, detail=f"Upstream fetch error: {e}")

    preview = resp.text[:300] if resp.text is not None else ""
    return {
        "requested_url": str(inp.url),
        "status_code": resp.status_code,
        "headers": dict(resp.headers),
        "body_preview": preview,
        "body_preview_len": len(preview),
    }
```
5. Rebuild and (re)start the function (this installs the new dependency and launches the service):
```
fnctl build test
```
6. Call the function through Traefik on port 8080 (adjust the IP if you’re calling from another host):
```
# You can run the following to get a template CURL command:
fnctl gencurl hello

# For reference, this is the CURL command to be used in this example
curl -s -X POST http://127.0.0.1:8080/fn/test/invoke -H 'Content-Type: application/json' -d '{"url":"https://httpbin.org/get"}'
```
7. Remove hello
```
fnctl destroy hello
```

## Contributing
Contributions are welcome! Fork the repo, make your changes, and submit a pull request.

## License
This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](https://github.com/vedantm8/python-fns/blob/main/LICENSE) file for details.
