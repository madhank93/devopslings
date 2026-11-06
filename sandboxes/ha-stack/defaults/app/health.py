# GET /health on web1 and web2 calls check(db). Return True to answer 200 and
# False to answer 503; a (bool, "detail") tuple adds a reason to the body.
# db() opens a new connection to the app's database. Saved changes apply to
# the next request.


def check(db):
    return True, "process is up"
