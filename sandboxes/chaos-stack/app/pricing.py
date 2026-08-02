"""pricing — the dependency. Fast, boring, and entirely healthy.

The lesson never breaks this service. Faults are injected into the network
between checkout and pricing, because that is where they happen in production:
the dependency is usually fine, and the path to it is not.
"""

from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/price")
def price():
    return jsonify(price=42.0)


if __name__ == "__main__":
    from waitress import serve

    print("pricing up on :8080", flush=True)
    serve(app, host="0.0.0.0", port=8080, threads=16)
