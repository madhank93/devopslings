#!/bin/sh
set -e

git checkout -q -b add-healthcheck

cat > healthcheck.sh << 'EOF'
#!/bin/sh
curl -sf http://localhost:8080/health
EOF
chmod +x healthcheck.sh
git add healthcheck.sh
git commit -q -m 'feat: add healthcheck script'

echo "Run healthcheck.sh to check the service is up." >> README.md
git add README.md
git commit -q -m 'docs: document the healthcheck'

git checkout -q main

# main has not moved since the branch was cut, so a plain merge would fast-forward
# and leave no record that a branch existed.
git merge --no-ff -m 'merge: add-healthcheck into main' add-healthcheck

cat > merge.md << 'EOF'
parents: 2
fast_forward: a straight line of the two commits, with no merge commit and nothing marking where they landed
records: that the two commits were one branch, and the point at which it was integrated into main
EOF
