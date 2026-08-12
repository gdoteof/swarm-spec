# Thin wrappers; scripts/check.sh is the real logic.

# Typecheck every spec file.
typecheck:
    npx quint typecheck specs/chuggernaut/types.qnt
    npx quint typecheck specs/chuggernaut/table.qnt
    npx quint typecheck specs/chuggernaut/tests/table_test.qnt

# Run the Quint unit tests.
test:
    npx quint test specs/chuggernaut/tests/table_test.qnt

# Full check pipeline (what CI runs).
check:
    bash scripts/check.sh
