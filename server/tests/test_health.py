from fastapi.testclient import TestClient


def test_health(tmp_path, monkeypatch):
    monkeypatch.setattr("app.config.DATABASE_PATH", str(tmp_path / "test.db"))
    from app.main import app

    with TestClient(app) as client:
        res = client.get("/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok"}


def test_루트는_테스트_콘솔로_보냄():
    from app.main import app

    with TestClient(app) as client:
        res = client.get("/", follow_redirects=False)
    assert res.status_code in (302, 307)
    assert res.headers["location"] == "/console"


def test_테스트_콘솔_페이지가_열림():
    from app.main import app

    with TestClient(app) as client:
        res = client.get("/console")
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("text/html")
    assert "/api/ask" in res.text
