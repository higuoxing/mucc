#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

CC="${CC:-gcc}"
TEST_CC="${TEST_CC:-$SCRIPT_DIR/mucc}"
TEST_KEEP_TMP="${TEST_KEEP_TMP:-0}"

compare=0
for arg in "$@"; do
    case "$arg" in
        --compare) compare=1 ;;
        -h|--help)
            printf 'Usage: %s [--compare]\nCompare exit codes with CC (default: gcc) when --compare is specified.\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\nUsage: %s [--compare]\n' "$arg" "$0" >&2
            exit 2
            ;;
    esac
done

passed=0
rejected=0

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-mucc.XXXXXX")
function cleanup() {
    if [[ "$TEST_KEEP_TMP" == 1 ]]; then
	printf 'Temporary files kept in %s\n' "$WORK_DIR" >&2
    else
	rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

function fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

function check() {
    local name=${1:-test$((passed + 1))}
    local expected=$2
    local source=$3
    local extra_source=${4:-} # Optional second translation unit.
    local base="$WORK_DIR/execute-$((passed + 1))"
    local input="$base.c"
    local assembly_inputs=("$base.s")
    local reference_inputs=("$input")
    local actual_code
    local reference_code

    printf '%s' "$source" > "$input"
    if "$TEST_CC" "$input" -o "$base.s" 2> "$base.compile.err"; then
	:
    else
	actual_code=$?
	cat "$base.compile.err" >&2
	fail "$name: compiler exited with status $actual_code"
    fi

    if [[ -n "$extra_source" ]]; then
        printf '%s' "$extra_source" > "$base.extra.c"
        if "$TEST_CC" "$base.extra.c" -o "$base.extra.s" 2> "$base.extra.compile.err"; then
            :
        else
            actual_code=$?
            cat "$base.extra.compile.err" >&2
            fail "$name: compiler exited with status $actual_code for second translation unit"
        fi
        assembly_inputs+=("$base.extra.s")
        reference_inputs+=("$base.extra.c")
    fi

    # Don't allow a stale executable to hide a linker that produced no output.
    rm -f -- "$base.out"
    if "$CC" "${assembly_inputs[@]}" -o "$base.out" > "$base.link.log" 2>&1; then
	:
    else
	actual_code=$?
	cat "$base.link.log" >&2
	fail "$name: assembler/linker exited with status $actual_code"
    fi
    [[ -f "$base.out" && -x "$base.out" ]] || fail "$name: linker produced no executable"

    if "$base.out" > "$base.stdout" 2> "$base.stderr"; then
	actual_code=0
    else
	actual_code=$?
    fi
    if [[ "$actual_code" -ne "$expected" ]]; then
        cat "$base.stdout" "$base.stderr" >&2
        printf 'Source: %q\n' "$source" >&2
        fail "$name (exit code $actual_code, expected $expected)"
    fi

    if ((compare)); then
        if "$CC" -std=c11 -O0 "${reference_inputs[@]}" -o "$base.reference.out" > "$base.reference.compile.log" 2>&1; then
            :
        else
            reference_code=$?
            cat "$base.reference.compile.log" >&2
            printf 'Source: %q\n' "$source" >&2
            fail "$name: reference compiler ($CC) exited with status $reference_code"
        fi
        [[ -f "$base.reference.out" && -x "$base.reference.out" ]] || fail "$name: reference compiler produced no executable"

        if "$base.reference.out" > "$base.reference.stdout" 2> "$base.reference.stderr"; then
            reference_code=0
        else
            reference_code=$?
        fi
        if [[ "$actual_code" -ne "$reference_code" ]]; then
            cat "$base.stdout" "$base.stderr" "$base.reference.stdout" "$base.reference.stderr" >&2
            printf 'Source: %q\n' "$source" >&2
            fail "$name: $TEST_CC exit code $actual_code, $CC exit code $reference_code, expected $expected"
        fi
    fi

    passed=$((passed + 1))
    if ((compare)); then
        printf '[PASS] %s (exit code %s, matches %s)\n' "$name" "$actual_code" "$CC"
    else
        printf '[PASS] %s (exit code %s)\n' "$name" "$actual_code"
    fi
}

function check_error() {
    local name=$1
    local source=$2
    local diag=$3
    local base="$WORK_DIR/reject-$((rejected + 1))"
    local input="$base.c"
    local actual_code

    printf '%s' "$source" > "$input"
    if "$TEST_CC" "$input" -o "$base.s" 2> "$base.err"; then
	actual_code=0
    else
	actual_code=$?
    fi

    # Crash, missing compiler, or accidental acceptance is not a rejection.
    if [[ $actual_code -ne 1 ]]; then
	cat "$base.err" >&2
	fail "$name: compiler exited with status $actual_code, expected 1"
    fi

    printf '%s:%s\n' "$input" "$diag" > "$base.expected.err"
    if ! cmp -s "$base.expected.err" "$base.err"; then
	printf 'Expected diagnostic:\n' >&2
	cat "$base.expected.err" >&2
	printf 'Actual diagnostic:\n' >&2
	cat "$base.err" >&2
	fail "$name: unexpected diagnostic"
    fi
    if [[ -s "$base.s" ]]; then
	fail "$name: emitted assembly for invalid input"
    fi

    rejected=$((rejected + 1))
    printf '[PASS] %s (rejected with expected diagnostic)\n' "$name"
}

# File-scope extern declarations share objects without allocating storage.
check extern-object-before-definition 42 'extern int x; int x = 42; int main(void) { return x; }'
check extern-object-after-definition 42 'int x = 42; extern int x; int main(void) { return x; }'
check extern-object-tentative-definition 0 'extern int x; int x; extern int x; int main(void) { return x; }'
check extern-object-initializer-definition 42 'extern int x = 42; int main(void) { return x; }'
check extern-object-initializer-after-declaration 42 'extern int x; extern int x = 42; extern int x; int main(void) { return x; }'
check extern-object-initializer-after-tentative 42 'int x; extern int x = 42; int x; int main(void) { return x; }'
check extern-object-repeated-declarations 42 'extern int x; extern int x; int x = 42; extern int x; int main(void) { return x; }'
check extern-object-declaration-list 42 'extern int a, b; int a = 20, b = 22; int main(void) { return a + b; }'
check extern-definition-list 42 'extern int a = 20, b = 22; int main(void) { return a + b; }'
check extern-after-type 42 'int extern x; int x = 42; int main(void) { return x; }'
check extern-between-type-specifiers 1 'unsigned extern long x; unsigned long x = 1UL << 40; int main(void) { return x == (1UL << 40); }'
check extern-with-const 42 'const extern int x; const int x = 42; int main(void) { return x; }'
check extern-typedef-type 42 'typedef int I; I extern x; I x = 42; int main(void) { return x; }'
check extern-incomplete-struct-declaration 0 'extern struct S x; int main(void) { return 0; }'
check extern-incomplete-array-declaration 0 'extern int a[]; int main(void) { return 0; }'
check extern-incomplete-struct-completed 42 'extern struct S x; struct S { int value; }; struct S x; int main(void) { x.value = 42; return x.value; }'
check extern-array-completes-tentative-definition 12 'int a[]; extern int a[3]; int main(void) { return sizeof a; }'
check extern-array-composite-bound 12 'extern int a[3]; int a[]; int main(void) { return sizeof a; }'
check extern-string-array-definition 42 'extern char text[]; char text[] = "*"; int main(void) { return text[0]; }'
check extern-string-array-initializer 42 'extern char text[] = "*"; extern char text[]; int main(void) { return text[0]; }'
check extern-pointer-address-initializer 42 'extern int x; int *p = &x; int x = 42; int main(void) { return *p; }'
check extern-preserves-static-object-linkage 42 'static int x = 42; extern int x; int main(void) { return x; }'
check extern-initializer-preserves-static-linkage 42 'static int x; extern int x = 42; int main(void) { return x; }'
check extern-then-repeat-static-object 42 'static int x; extern int x; static int x = 42; int main(void) { return x; }'
check extern-function-prototype 42 'extern int f(int); int f(int x) { return x; } int main(void) { return f(42); }'
check extern-function-definition 42 'extern int f(void) { return 42; } int main(void) { return f(); }'
check extern-function-after-definition 42 'int f(void) { return 42; } extern int f(void); int main(void) { return f(); }'
check extern-function-inherits-static-linkage 42 'static int f(void); extern int f(void) { return 42; } int main(void) { return f(); }'
check extern-function-then-repeat-static 42 'static int f(void); extern int f(void); static int f(void) { return 42; } int main(void) { return f(); }'
check extern-function-refines-prototype 42 'extern int f(); extern int f(int); int f(int x) { return x; } int main(void) { return f(42); }'
check extern-object-local-shadowing 42 'extern int x; int x = 42; int main(void) { { int x = 1; x++; } return x; }'
check extern-unused-object-no-definition 42 'extern int missing; int main(void) { return 42; }'
check extern-keyword-boundaries 42 'int main(void) { int external = 20; int extern_ = 21; int extern1 = 1; return external + extern_ + extern1; }'
check \
    extern-object-another-translation-unit \
    42 \
    'extern int shared; int main(void) { return shared; }' \
    'int shared = 42;'
check \
    extern-object-write-another-translation-unit \
    42 \
    'extern int shared; int read_shared(void); int main(void) { shared = 42; return read_shared(); }' \
    'int shared; int read_shared(void) { return shared; }'
check \
    extern-function-another-translation-unit \
    42 \
    'extern int other(int); int main(void) { return other(42); }' \
    'int other(int x) { return x; }'
check \
    extern-definition-exports-object \
    42 \
    'extern int shared = 42; int other(void); int main(void) { return other(); }' \
    'extern int shared; int other(void) { return shared; }'
check \
    extern-static-object-separate-translation-units \
    42 \
    'static int shared = 20; extern int shared; int other(void); int main(void) { return shared + other(); }' \
    'int shared = 22; int other(void) { return shared; }'
check \
    extern-static-function-separate-translation-units \
    42 \
    'static int shared(void); extern int shared(void) { return 20; } int other(void); int main(void) { return shared() + other(); }' \
    'int shared(void) { return 22; } int other(void) { return shared(); }'

check_error extern-duplicate-storage 'extern extern int x;' \
            "1:8: error: duplicate extern specifier"
check_error extern-duplicate-storage-after-type 'extern int extern x;' \
            "1:12: error: duplicate extern specifier"
check_error extern-with-static 'extern static int x;' \
            "1:8: error: multiple storage classes in declaration"
check_error extern-after-static 'static int extern x;' \
            "1:12: error: multiple storage classes in declaration"
check_error extern-with-typedef 'extern typedef int T;' \
            "1:8: error: multiple storage classes in declaration"
check_error extern-after-typedef 'typedef int extern T;' \
            "1:13: error: multiple storage classes in declaration"
check_error extern-parameter 'int f(extern int x);' \
            "1:7: error: extern is not allowed here"
check_error extern-member 'struct S { extern int x; };' \
            "1:12: error: extern is not allowed here"
check_error extern-sizeof-type 'int main(void) { return sizeof(extern int); }' \
            "1:32: error: extern is not allowed here"
check_error extern-cast-type 'int main(void) { return (extern int)1; }' \
            "1:26: error: extern is not allowed here"
check_error extern-for-initializer 'int main(void) { for (extern int x; ; ) {} }' \
            "1:23: error: extern is not allowed in a for initializer"
check_error extern-static-variable-conflict 'extern int x; static int x;' \
            "1:26: error: static declaration of 'x' follows non-static declaration"
check_error extern-static-function-conflict 'extern int f(void); static int f(void);' \
            "1:32: error: static declaration of 'f' follows non-static declaration"
check_error extern-object-type-conflict 'extern int x; long x;' \
            "1:20: error: conflicting declaration of variable 'x'"
check_error extern-object-const-conflict 'extern const int x; int x;' \
            "1:25: error: conflicting declaration of variable 'x'"
check_error extern-array-bound-conflict 'extern int a[2]; int a[3];' \
            "1:22: error: conflicting declaration of variable 'a'"
check_error extern-function-type-conflict 'extern int f(int); int f(long);' \
            "1:24: error: conflicting declaration of function 'f'"
check_error extern-variable-redefinition 'extern int x = 1; int x = 2;' \
            "1:23: error: redefinition of variable 'x'"
check_error extern-static-variable-redefinition 'static int x = 1; extern int x = 2;' \
            "1:30: error: redefinition of variable 'x'"
check_error extern-variable-typedef-conflict 'typedef int T; extern int T;' \
            "1:27: error: variable conflicts with typedef 'T'"
check_error extern-function-variable-conflict 'int f; extern int f(void);' \
            "1:19: error: function conflicts with variable 'f'"
check_error extern-variable-function-conflict 'int f(void); extern int f;' \
            "1:25: error: variable conflicts with function 'f'"
check_error extern-void-object 'extern void x;' \
            "1:13: error: variable has void type"
check_error extern-incomplete-object-definition 'extern struct S x; struct S x;' \
            "1:29: error: variable has incomplete type"
check_error extern-incomplete-array-sizeof 'extern int a[]; int main(void) { return sizeof a; }' \
            "1:41: error: sizeof cannot be applied to an incomplete type"
check_error extern-nonconstant-initializer 'int f(void); extern int x = f();' \
            "1:29: error: global initializer is not a constant expression"
check_error extern-missing-type 'extern x;' \
            "1:8: error: expect type specifier"
check_error extern-missing-name 'int extern;' \
            "1:11: error: expect declaration name"
check_error extern-keyword-as-variable 'int main() { int extern; return 0; }' \
            "1:24: error: expect variable name"
check_error extern-unbraced-declaration 'int main(void) { if (1) extern int x; return 0; }' \
            "1:25: error: expect statement"
check_error extern-block-object-not-supported 'int main(void) { extern int x; return 0; }' \
            "1:29: error: block-scope extern declarations are not supported yet"
check_error extern-block-function-not-supported 'int main(void) { extern int f(void); return 0; }' \
            "1:29: error: block-scope extern declarations are not supported yet"

# File-scope static declarations retain internal linkage across redeclarations.
check static-global-zero 0 'static int x; int main(void) { return x; }'
check static-global-initializer 42 'static int x = 42; int main(void) { return x; }'
check static-after-type 42 'int static x = 42; int main(void) { return x; }'
check static-between-type-specifiers 1 'unsigned static long x = 1UL << 40; int main(void) { return x == (1UL << 40); }'
check static-with-const 42 'const static int x = 42; int main(void) { return x; }'
check static-typedef-type 42 'typedef int I; I static x = 42; int main(void) { I y = 0; y = x; return y; }'
check static-tentative-definition 42 'static int x; static int x = 42; static int x; int main(void) { return x; }'
check static-declaration-list 42 'static int a = 20, b = 22; int main(void) { return a + b; }'
check static-address-initializer 42 'static int x = 42; static int *p = &x; int main(void) { return *p; }'
check static-string-completes-array 42 'static char text[] = "*"; static char text[]; int main(void) { return text[0]; }'
check static-composite-array-type 8 'static int a[2]; static int a[]; int main(void) { return sizeof a; }'
check static-struct-object 42 'static struct S { int x; } s; int main(void) { s.x = 42; return s.x; }'
check static-enum-object 42 'static enum E { A = 42 } x = A; int main(void) { return x; }'
check static-object-shadowing 42 'static int x = 42; int main(void) { { int x = 1; x++; } return x; }'
check static-function-definition 42 'static int f(void) { return 42; } int main(void) { return f(); }'
check static-function-specifier-order 42 'int static f(void) { return 42; } int main(void) { return f(); }'
check static-function-inherits-linkage 42 'static int f(int); int f(int x) { return x; } int main(void) { return f(42); }'
check static-function-redeclarations 42 'static int f(void); int f(void); static int f(void) { return 42; } int main(void) { return f(); }'
check static-function-later-plain-prototype 42 'static int f(void) { return 42; } int f(void); int main(void) { return f(); }'
check static-function-refines-prototype 42 'static int f(); int f(int x) { return x; } int main(void) { return f(42); }'
check static-function-name-hidden-by-parameter 42 'static int f(int f); int f(int f) { return f; } int main(void) { return f(42); }'
check static-recursion 120 'static int fact(int n) { if (n < 2) return 1; return n * fact(n - 1); } int main(void) { return fact(5); }'
check static-unused-prototype 42 'static int unused(void); int main(void) { return 42; }'
check static-keyword-boundaries 42 'int main(void) { int statically = 20; int static_ = 21; int static1 = 1; return statically + static_ + static1; }'

# Static symbols with the same spelling belong to their own translation units.
check \
    static-separate-translation-units \
    42 \
    'static int value = 20; static int zero; static char text[] = "*"; static int *ptr = &value; static int helper(void); int helper(void) { return *ptr + zero; } int helper(void); int other(void); int main(void) { if (text[0] != 42) return 99; zero = 1; return helper() + other(); }' \
    'static int value = 21; static int zero; static char text[] = "+"; static int *ptr = &value; static int helper(void) { return *ptr + zero; } int other(void) { if (zero != 0 || text[0] != 43 || *ptr != 21) return 100; return helper(); }'
check \
    static-object-independent-of-external \
    42 \
    'static int shared = 20; int other(void); int main(void) { return shared + other(); }' \
    'int shared = 22; int other(void) { return shared; }'
check \
    static-function-independent-of-external \
    42 \
    'static int shared(void) { return 20; } int other(void); int main(void) { return shared() + other(); }' \
    'int shared(void) { return 22; } int other(void) { return shared(); }'

check_error static-variable-after-external 'int x; static int x;' \
            "1:19: error: static declaration of 'x' follows non-static declaration"
check_error static-variable-before-external 'static int x; int x;' \
            "1:19: error: non-static declaration of 'x' follows static declaration"
check_error static-variable-after-definition 'int x = 1; static int x;' \
            "1:23: error: static declaration of 'x' follows non-static declaration"
check_error static-variable-later-external-definition 'static int x; int x = 1;' \
            "1:19: error: non-static declaration of 'x' follows static declaration"
check_error static-function-after-external 'int f(void); static int f(void);' \
            "1:25: error: static declaration of 'f' follows non-static declaration"
check_error static-function-after-external-definition 'int f(void) { return 0; } static int f(void);' \
            "1:38: error: static declaration of 'f' follows non-static declaration"
check_error static-duplicate-storage 'static static int x;' \
            "1:8: error: duplicate static specifier"
check_error static-duplicate-storage-after-type 'static int static x;' \
            "1:12: error: duplicate static specifier"
check_error static-with-typedef 'static typedef int T;' \
            "1:8: error: multiple storage classes in declaration"
check_error static-after-typedef 'typedef int static T;' \
            "1:13: error: multiple storage classes in declaration"
check_error static-parameter 'int f(static int x);' \
            "1:7: error: static is not allowed here"
check_error static-unnamed-parameter 'int f(int static);' \
            "1:11: error: static is not allowed here"
check_error static-member 'struct S { static int x; };' \
            "1:12: error: static is not allowed here"
check_error static-sizeof-type 'int main(void) { return sizeof(static int); }' \
            "1:32: error: static is not allowed here"
check_error static-cast-type 'int main(void) { return (static int)1; }' \
            "1:26: error: static is not allowed here"
check_error static-for-initializer 'int main(void) { for (static int x = 0; x < 1; x++) {} return 0; }' \
            "1:23: error: static is not allowed in a for initializer"
check_error static-incomplete-array 'static int a[];' \
            "1:12: error: static variable has incomplete type"
check_error static-array-completed-too-late 'static int a[]; static int a[2];' \
            "1:12: error: static variable has incomplete type"
check_error static-incomplete-struct 'static struct S x; struct S { int a; };' \
            "1:17: error: static variable has incomplete type"
check_error static-incomplete-const-struct 'static const struct S x; struct S { int a; };' \
            "1:23: error: static variable has incomplete type"
check_error static-conflicting-variable-type 'static int x; static long x;' \
            "1:27: error: conflicting declaration of variable 'x'"
check_error static-conflicting-function-type 'static int f(int); static int f(long);' \
            "1:31: error: conflicting declaration of function 'f'"
check_error static-variable-redefinition 'static int x = 1; static int x = 2;' \
            "1:30: error: redefinition of variable 'x'"
check_error static-function-redefinition 'static int f(void) { return 1; } int f(void) { return 2; }' \
            "1:38: error: redefinition of function 'f'"
check_error static-variable-typedef-conflict 'typedef int T; static int T;' \
            "1:27: error: variable conflicts with typedef 'T'"
check_error static-function-variable-conflict 'int f; static int f(void);' \
            "1:19: error: function conflicts with variable 'f'"
check_error static-nonconstant-initializer 'int f(void); static int x = f();' \
            "1:29: error: global initializer is not a constant expression"
check_error static-missing-type 'static x;' \
            "1:8: error: expect type specifier"
check_error static-missing-name 'int static;' \
            "1:11: error: expect declaration name"
check_error static-keyword-as-variable 'int main() { int static; return 0; }' \
            "1:24: error: expect variable name"
check_error static-unbraced-declaration 'int main(void) { if (1) static int x; return 0; }' \
            "1:25: error: expect statement"
check_error static-local-not-supported 'int main(void) { static int x; return 0; }' \
            "1:29: error: static local variables are not supported yet"
check_error static-local-initializer-not-supported 'int main(void) { int static x = 1; return x; }' \
            "1:29: error: static local variables are not supported yet"

# Const qualification applies independently to objects and pointed-to types.
check const-local-int 42 'int main(void) { const int x = 42; return x; }'
check const-specifier-order 42 'int main(void) { int const x = 42; return x; }'
check const-repeated-qualifier 42 'int main(void) { const const int const x = 42; return x; }'
check const-mixed-specifiers 1 'int main(void) { unsigned const long const x = 1UL << 40; return x == (1UL << 40); }'
check const-small-integers 1 'int main(void) { const char a = -1; const short b = -2; const _Bool c = 256; return a == -1 && b == -2 && c == 1; }'
check const-global-definition 42 'const int x = 42; const int x; int main(void) { return x; }'
check const-global-zero 0 'const int x; int main(void) { return x; }'
check const-global-widths 1 'const char a = -1; const unsigned long b = 18446744073709551615UL; int main(void) { return a == -1 && b == 18446744073709551615UL; }'
check const-builtin-not-mutated 42 'const int c = 1; int main(void) { int x = 1; x = 42; return x; }'
check const-typedef-not-mutated 42 'typedef int I; const I c = 1; int main(void) { I x = 1; x = 42; return x; }'
check const-typedef-const 42 'typedef const int I; typedef const int I; int main(void) { I x = 42; return x; }'
check const-typedef-repeated-const 42 'typedef int I; typedef const I CI; typedef CI const CI; int main(void) { CI x = 42; return x; }'
check const-typedef-name-as-identifier 42 'typedef const int T; int main(void) { T const T = 42; return T; }'
check const-pointer-to-const 42 'int main(void) { int x = 42; const int *p = &x; return *p; }'
check const-const-pointer 42 'int main(void) { int x = 1; int *const p = &x; *p = 42; return x; }'
check const-const-pointer-to-const 42 'int main(void) { int x = 42; const int *const p = &x; return *p; }'
check const-repeated-pointer-qualifier 42 'int main(void) { int x = 1; int * const const p = &x; *p = 42; return x; }'
check const-pointer-typedef-not-mutated 1 'typedef int *P; int main(void) { int x; P p = &x; const P q = p; p = 0; return q == &x && p == 0; }'
check const-explicit-cast-removes-const 42 'int main(void) { int x = 1; const int *p = &x; *(int *)p = 42; return x; }'
check const-void-pointer-add-qualifier 42 'int main(void) { int x = 42; void *v = &x; const int *p = v; return *p; }'
check const-const-void-pointer 42 'int main(void) { int x = 42; const void *v = &x; const int *p = v; return *p; }'
check const-null-pointer 1 'int main(void) { const int *p = 0; const void *q = 0; return p == 0 && q == 0; }'
check const-add-inner-pointer-const 42 'int main(void) { int x = 1; int *p = &x; int *const *q = &p; **q = 42; return x; }'
check const-nested-compatible-pointer 42 'int main(void) { int x = 42; const int *p = &x; const int *const *q = &p; return **q; }'
check const-mutable-pointer-assignment 1 'int main(void) { int x = 42; const int *p; p = &x; return *p == 42; }'
check const-const-parameter 42 'int f(const int x) { return x; } int main(void) { return f(42); }'
check const-parameter-qualifier-compatibility 42 'int f(const int); int f(int x) { x += 1; return x; } int main(void) { return f(41); }'
check const-parameter-qualifier-reversed 42 'int f(int); int f(const int x) { return x; } int main(void) { return f(42); }'
check const-pointer-parameter-top-qualifier 42 'int f(int *); int f(int *const p) { *p = 42; return *p; } int main(void) { int x; return f(&x); }'
check const-argument-add-qualifier 42 'int f(const int *p) { return *p; } int main(void) { int x = 42; return f(&x); }'
check const-return-add-qualifier 42 'int x = 42; const int *f(void) { return &x; } int main(void) { return *f(); }'
check const-qualified-return-value 42 'const int f(void) { return 42; } int main(void) { return f(); }'
check const-prototype-promotion-compatibility 42 'int f(); int f(const int x) { return x; } int main(void) { return f(42); }'
check const-default-argument-promotion 42 'int f(); int main(void) { const char c = 41; return f(c); } int f(int x) { return x + 1; }'
check const-scalar-promotion 1 'int main(void) { const int x = 1; const unsigned y = 2; return -x == -1 && ~x == -2 && x+y == 3 && x << 3 == 8; }'
check const-switch-promotion 42 'int main(void) { const int x = 1; switch(x) { case 1: return 42; default: return 0; } }'
check const-condition 42 'int main(void) { const int x = 1; if (x) return 42; return 0; }'
check const-conditional-scalar 1 'int main(void) { const int x = 1; int y = 2; return (1 ? x : y) == 1 && (0 ? x : y) == 2; }'
check const-conditional-add-qualifier 42 'int main(void) { int x = 42; int *p = &x; const int *q = p; const int *r = 1 ? p : q; return *r; }'
check const-conditional-add-qualifier-reversed 42 'int main(void) { int x = 42; int *p = &x; const int *q = p; const int *r = 1 ? q : p; return *r; }'
check const-conditional-const-void 42 'int main(void) { int x = 42; const int *p = &x; void *q = &x; const void *r = 1 ? p : q; return *(const int *)r; }'
check const-conditional-const-void-reversed 42 'int main(void) { int x = 42; const int *p = &x; void *q = &x; const void *r = 1 ? q : p; return *(const int *)r; }'
check const-array-element-qualification 42 'int main(void) { const int a[2]; int b[2]; b[1] = 42; const int *p = b; return p[1]; }'
check const-array-typedef-not-mutated 1 'typedef int A[2]; const A a; int main(void) { A b; b[0] = 42; return sizeof(a) == 8 && b[0] == 42; }'
check const-array-parameter 42 'int f(const int a[]) { return a[1]; } int main(void) { int a[2]; a[1] = 42; return f(a); }'
check const-local-string-array 98 'int main(void) { const char a[] = "abc"; const char *p = a; return p[1]; }'
check const-global-string-array 98 'const char a[] = "abc"; int main(void) { return a[1]; }'
check const-string-pointer 98 'int main(void) { const char *p = "abc"; return p[1]; }'
check const-pointer-arithmetic 1 'int main(void) { int a[3]; const int *p = a; p++; ++p; p--; --p; return p == a && p - a == 0 && a + 2 - p == 2; }'
check const-enum-qualification 1 'enum E { A = 42 }; int main(void) { const enum E e = A; return e == 42 && sizeof(e) == 4; }'
check const-struct-pointer 42 'struct S { int x; }; int main(void) { struct S s; s.x = 42; const struct S *p = &s; return p->x; }'
check const-global-const-struct 0 'struct S { int x; }; const struct S s; int main(void) { return s.x; }'
check const-const-struct-pointer-member 42 'struct S { int *p; }; int main(void) { int x; struct S s; s.p = &x; const struct S *p = &s; *p->p = 42; return x; }'
check const-const-not-transitive-through-pointer 42 'struct N { int x; struct N *next; }; int main(void) { struct N a; struct N b; a.next = &b; const struct N *p = &a; p->next->x = 42; return b.x; }'
check const-qualified-struct-identity 1 'struct S { int x; }; int main(void) { struct S s; const struct S *p = &s; return p - &s == 0; }'
check const-anonymous-struct-identity 42 'typedef struct { int x; } S; int main(void) { S s; s.x = 42; const S *p = &s; return p->x; }'
check const-forward-qualified-struct 42 'struct S; const struct S *p; struct S { int x; }; int main(void) { struct S s; s.x = 42; p = &s; return p->x; }'
check const-forward-struct-size-and-step 1 'struct S; typedef const struct S CS; struct S { long x; }; int main(void) { CS a[2]; const struct S *p = a; p++; --p; return sizeof(a) == 16 && p+1-p == 1; }'
check const-forward-global-qualified-object 0 'struct S; const struct S s; struct S { int x; }; int main(void) { return s.x; }'
check const-sizeof-qualified-types 1 'int main(void) { return sizeof(const int) == 4 && sizeof(int *const) == 8 && sizeof(const int[2]) == 8; }'
check const-qualified-cast 42 'int main(void) { return (const int)42; }'
check const-keyword-boundaries 42 'int main(void) { int constancy = 20; int const_ = 22; return constancy + const_; }'
check_error const-assign-object 'int main(void) { const int x = 1; x = 2; return x; }' \
            '1:37: error: invalid assignment target'
check_error const-compound-object 'int main(void) { const int x = 1; x += 2; return x; }' \
            '1:37: error: invalid assignment target'
check_error const-increment-object 'int main(void) { const int x = 1; ++x; return x; }' \
            '1:35: error: invalid increment target'
check_error const-decrement-object 'int main(void) { const int x = 1; x--; return x; }' \
            '1:36: error: invalid decrement target'
check_error const-assign-through-pointer 'int main(void) { int x; const int *p = &x; *p = 1; return 0; }' \
            '1:47: error: invalid assignment target'
check_error const-increment-through-pointer 'int main(void) { int x; const int *p = &x; (*p)++; return 0; }' \
            '1:48: error: invalid increment target'
check_error const-assign-pointer 'int main(void) { int x; int *const p = &x; p = 0; return 0; }' \
            '1:46: error: invalid assignment target'
check_error const-increment-pointer 'int main(void) { int x; int *const p = &x; p++; return 0; }' \
            '1:45: error: invalid increment target'
check_error const-assign-array-element 'int main(void) { const int a[2]; a[0] = 1; return 0; }' \
            '1:39: error: invalid assignment target'
check_error const-assign-array-typedef 'typedef int A[2]; int main(void) { const A a; a[0] = 1; return 0; }' \
            '1:52: error: invalid assignment target'
check_error const-assign-string-array 'int main(void) { const char a[] = "abc"; a[0] = 1; return 0; }' \
            '1:47: error: invalid assignment target'
check_error const-assign-parameter 'int f(const int x) { x = 1; return x; }' \
            '1:24: error: invalid assignment target'
check_error const-assign-pointer-parameter 'int f(int *const p) { p = 0; return 0; }' \
            '1:25: error: invalid assignment target'
check_error const-assign-array-parameter 'int f(const int a[]) { a[0] = 1; return 0; }' \
            '1:29: error: invalid assignment target'
check_error const-assign-struct-member 'struct S { int x; }; int main(void) { const struct S s; s.x = 1; return 0; }' \
            '1:61: error: invalid assignment target'
check_error const-assign-arrow-member 'struct S { int x; }; int main(void) { struct S s; const struct S *p = &s; p->x = 1; return 0; }' \
            '1:80: error: invalid assignment target'
check_error const-assign-nested-member 'struct I { int x; }; struct O { struct I i; }; int main(void) { const struct O o; o.i.x = 1; return 0; }' \
            '1:89: error: invalid assignment target'
check_error const-assign-member-array 'struct S { int a[2]; }; int main(void) { const struct S s; s.a[0] = 1; return 0; }' \
            '1:67: error: invalid assignment target'
check_error const-assign-member-pointer 'struct S { int *p; }; int main(void) { const struct S s; s.p = 0; return 0; }' \
            '1:62: error: invalid assignment target'
check_error const-assign-explicit-const-member 'struct S { const int x; }; int main(void) { struct S s; s.x = 1; return 0; }' \
            '1:61: error: invalid assignment target'
check_error const-discard-pointer-initializer 'int main(void) { const int x = 1; int *p = &x; return 0; }' \
            '1:40: error: incompatible initializer type'
check_error const-discard-pointer-assignment 'int main(void) { int *p; const int *q = 0; p = q; return 0; }' \
            '1:46: error: incompatible assignment type'
check_error const-discard-pointer-argument 'int f(int *p); int main(void) { const int x = 1; return f(&x); }' \
            '1:59: error: incompatible argument type'
check_error const-discard-pointer-return 'const int x = 1; int *f(void) { return &x; }' \
            '1:33: error: incompatible return type'
check_error const-discard-void-initializer 'int main(void) { const void *p = 0; int *q = p; return 0; }' \
            '1:42: error: incompatible initializer type'
check_error const-discard-to-void 'int main(void) { const int *p = 0; void *q = p; return 0; }' \
            '1:42: error: incompatible initializer type'
check_error const-discard-member-address 'struct S { int x; }; int main(void) { const struct S s; int *p = &s.x; return 0; }' \
            '1:62: error: incompatible initializer type'
check_error const-discard-array-typedef 'typedef int A[2]; int main(void) { const A a; int *p = a; return 0; }' \
            '1:52: error: incompatible initializer type'
check_error const-discard-conditional 'int main(void) { int *p = 0; const int *q = 0; int *r = 1 ? p : q; return 0; }' \
            '1:53: error: incompatible initializer type'
check_error const-discard-conditional-reversed 'int main(void) { int *p = 0; const int *q = 0; int *r = 1 ? q : p; return 0; }' \
            '1:53: error: incompatible initializer type'
check_error const-discard-qualified-void-null 'int main(void) { int x; int *p = 1 ? &x : (const void *)0; return 0; }' \
            '1:30: error: incompatible initializer type'
check_error const-unsafe-nested-pointer 'int main(void) { int **p = 0; const int **q = p; return 0; }' \
            '1:43: error: incompatible initializer type'
check_error const-unsafe-nested-pointer-with-const 'int main(void) { int **p = 0; const int *const *q = p; return 0; }' \
            '1:49: error: incompatible initializer type'
check_error const-discard-inner-pointer-const 'int main(void) { int x; int *const p = &x; int **q = &p; return 0; }' \
            '1:50: error: incompatible initializer type'
check_error const-parameter-pointee-conflict 'int f(int *p); int f(const int *p);' \
            "1:20: error: conflicting declaration of function 'f'"
check_error const-global-qualifier-conflict 'const int x; int x;' \
            "1:18: error: conflicting declaration of variable 'x'"
check_error const-typedef-qualifier-conflict 'typedef int T; typedef const int T;' \
            "1:34: error: conflicting typedef for 'T'"
check_error const-typedef-pointer-qualifier-conflict 'typedef int *T; typedef int *const T;' \
            "1:36: error: conflicting typedef for 'T'"
check_error const-qualified-void-parameter 'int f(const void);' \
            '1:17: error: parameter has void type'
check_error const-qualifier-without-type 'int main(void) { const x; return 0; }' \
            '1:24: error: expect type specifier'
check_error const-incomplete-qualified-sizeof 'struct S; int main(void) { return sizeof(const struct S); }' \
            '1:35: error: sizeof cannot be applied to an incomplete type'
check_error const-incomplete-qualified-step 'struct S; int main(void) { const struct S *p = 0; p++; return 0; }' \
            '1:52: error: pointer arithmetic on incomplete type'
check_error const-const-object-not-integer-constant 'const int n = 2; int a[n];' \
            '1:25: error: not an integer constant expression'
check_error const-const-object-not-static-initializer 'const int n = 2; int m = n;' \
            '1:26: error: global initializer is not a constant expression'
check_error const-conditional-unsafe-nested-pointer 'int main(void) { int **p = 0; const int **q = 0; return sizeof(1 ? p : q); }' \
            '1:66: error: incompatible conditional operand types'
check_error const-forward-qualified-write 'struct S; const struct S *p; struct S { int x; }; int main(void) { p->x = 1; return 0; }' \
            '1:73: error: invalid assignment target'
check_error const-reserved-keyword 'int main() { int const; return 0; }' \
            '1:23: error: expect variable name'

# Recursive scalar initializer evaluation keeps address and integer contexts separate.
check constant-nested-integer-cast 1 'int x; int b = (_Bool)&x; int main(void) { return b; }'
check constant-nested-narrow-cast 1 'int x; unsigned char b = (unsigned char)(_Bool)&x; int main(void) { return b; }'
check constant-nested-wide-cast 1 'int x; long b = (long)(_Bool)(_Bool)&x; int main(void) { return b; }'
check constant-conditional-bool 1 'int x; _Bool b = 1 ? (_Bool)&x : 0; int main(void) { return b; }'
check constant-conditional-bool-zero 0 'int x; _Bool b = 0 ? (_Bool)&x : 0; int main(void) { return b; }'
check constant-logical-null 1 '_Bool b = !(void *)0; int main(void) { return b; }'
check constant-logical-address 0 'int x; int b = !&x; int main(void) { return b; }'
check constant-address-ne-null 1 'int x; _Bool b = &x != 0; int main(void) { return b; }'
check constant-address-eq-null 0 'int x; int b = &x == (void *)0; int main(void) { return b; }'
check constant-null-ne-address 1 'int x; int b = 0 != &x; int main(void) { return b; }'
check constant-null-eq-null 1 'int b = (void *)0 == (int *)0; int main(void) { return b; }'
check constant-numeric-pointer-eq 1 'int b = (int *)256 == (int *)256; int main(void) { return b; }'
check constant-high-pointer-ne-null 1 'int b = (void *)4294967296UL != 0; int main(void) { return b; }'
check constant-same-object-address 1 'int x; int b = &x == &x; int main(void) { return b; }'
check constant-same-object-address-ne 0 'int x; int b = &x != &x; int main(void) { return b; }'
check constant-same-array-offset 1 'int a[3]; int b = &a[2] == a + 2; int main(void) { return b; }'
check constant-different-array-offset 0 'int a[3]; int b = a == a + 1; int main(void) { return b; }'
check constant-member-address-comparison 1 'struct S { int a; int b; }; struct S s; int b = &s.a != &s.b; int main(void) { return b; }'
check constant-array-relational 1 'int a[3]; int b = a < a + 1; int main(void) { return b; }'
check constant-array-relational-false 0 'int a[3]; int b = a + 1 <= a; int main(void) { return b; }'
check constant-arithmetic-after-address-bool 1 'int x; int b = (_Bool)&x + 41; int main(void) { return b == 42; }'
check constant-unary-after-address-bool 1 'int x; int b = ~(_Bool)&x; int main(void) { return b == -2; }'
check constant-bool-from-arithmetic-zero 0 'int x; _Bool b = (_Bool)&x - 1; int main(void) { return b; }'
check constant-bool-from-arithmetic-nonzero 1 'int x; _Bool b = (_Bool)&x + 255; int main(void) { return b; }'
check constant-logical-and-address 1 'int x; int b = &x && (_Bool)(void *)4294967296UL; int main(void) { return b; }'
check constant-short-circuit-call 1 'int f(void); int x; int b = &x || f(); int main(void) { return b; }'
check constant-short-circuit-null 0 'int f(void); int b = (void *)0 && f(); int main(void) { return b; }'
check constant-conditional-skips-invalid-branch 1 'int x; int b = &x ? 1 : 1 / 0; int main(void) { return b; }'
check constant-pointer-conditional-bool 42 'int x = 42; int *p = (_Bool)&x ? &x : 0; int main(void) { return *p; }'
check constant-pointer-conditional-address 42 'int x = 42; int *p = &x ? &x : 0; int main(void) { return *p; }'
check constant-pointer-conditional-logical 42 'int x = 42; int *p = !(void *)0 ? &x : 0; int main(void) { return *p; }'
check constant-nested-lvalue-address 42 'int x = 42; int *p = &*(&x ? &x : 0); int main(void) { return *p; }'
check constant-pointer-relocation-preserved 1 'int a[2]; char *p = (char *)a + 4; _Bool b = (_Bool)((char *)a + 4); int main(void) { return b && p == (char *)&a[1]; }'
check constant-shift-after-address-bool 1 'int x; int b = (_Bool)&x << 8; int main(void) { return b == 256; }'
check constant-unsigned-wrap-after-address-bool 0 'int x; unsigned b = (unsigned)(_Bool)&x + 4294967295U; int main(void) { return b; }'
check constant-nested-narrowing-before-bool 1 'int x; _Bool b = (_Bool)(unsigned char)((_Bool)&x + 255); int main(void) { return b == 0; }'
check_error constant-integer-enum-address 'int x; enum { A = (_Bool)&x + 1 };' \
            '1:33: error: not an integer constant expression'
check_error constant-integer-array-address 'int x; int a[(_Bool)&x + 1];' \
            '1:27: error: not an integer constant expression'
check_error constant-integer-case-address 'int x; int main(void) { switch(1) { case (_Bool)&x: return 1; } return 0; }' \
            '1:51: error: not an integer constant expression'
check_error constant-integer-enum-logical-address 'int x; enum { A = !&x };' \
            '1:23: error: not an integer constant expression'
check_error constant-integer-enum-comparison-address 'int x; enum { A = &x != 0 };' \
            '1:27: error: not an integer constant expression'
check_error constant-integer-array-conditional-address 'int x; int a[&x ? 1 : 2];' \
            '1:24: error: not an integer constant expression'
check_error constant-initializer-nested-variable 'int x; int b = (_Bool)x;' \
            '1:16: error: global initializer is not a constant expression'
check_error constant-initializer-nested-pointer-variable 'int x; int *p = &x; int b = (int)(_Bool)p;' \
            '1:29: error: global initializer is not a constant expression'
check_error constant-initializer-address-with-dynamic-condition 'int n, x; int b = n ? (_Bool)&x : 0;' \
            '1:21: error: global initializer is not a constant expression'
check_error constant-initializer-address-with-evaluated-call 'int f(void); int x; int b = &x && f();' \
            '1:32: error: global initializer is not a constant expression'
check_error constant-initializer-logical-pointer-read 'int *p = 0; int b = !p;' \
            '1:21: error: global initializer is not a constant expression'
check_error constant-initializer-address-comma 'int x; int b = (0, (_Bool)&x);' \
            '1:18: error: global initializer is not a constant expression'
check_error constant-initializer-address-assignment 'int x; _Bool b; int n = (b = &x);' \
            '1:28: error: global initializer is not a constant expression'
check_error constant-initializer-address-arithmetic-overflow 'int x; int n = (_Bool)&x + 2147483647;' \
            '1:38: error: integer overflow in constant expression'
check_error constant-initializer-address-arithmetic-division-zero 'int x; int n = (_Bool)&x / 0;' \
            '1:29: error: division by zero in constant expression'
check_error constant-initializer-address-arithmetic-invalid-shift 'int x; int n = (_Bool)&x << 32;' \
            '1:31: error: invalid shift count in constant expression'

check_error constant-integer-null-cast-enum 'enum { A = (_Bool)(void *)0 };' \
            '1:29: error: not an integer constant expression'
check_error constant-null-pointer-from-address-expression 'int x; int *p = (_Bool)&x - 1;' \
            '1:13: error: incompatible initializer type'
check_error constant-address-offset-not-integer-constant 'int a[2]; int *p = a + ((_Bool)&a - 1);' \
            '1:22: error: global initializer is not a constant expression'

# _Bool codegen: scalar conversions, byte storage, updates and calls.
check bool-runtime-init-zero 0 'int main(void) { _Bool b = 0; return b; }'
check bool-runtime-init-one 1 'int main(void) { _Bool b = 1; return b; }'
check bool-runtime-init-negative 1 'int main(void) { _Bool b = -1; return b; }'
check bool-runtime-init-not-byte-truncation 1 'int main(void) { _Bool b = 256; return b; }'
check bool-runtime-init-high-bits 1 'int main(void) { _Bool b = 4294967296UL; return b; }'
check bool-runtime-init-unsigned-max 1 'int main(void) { _Bool b = 18446744073709551615ULL; return b; }'
check bool-runtime-init-narrowed-zero 0 'int main(void) { _Bool b = (unsigned char)256; return b; }'
check bool-runtime-cast-int 1 'int main(void) { int n = 256; return (_Bool)n; }'
check bool-runtime-cast-long 1 'int main(void) { long n = 1L << 40; return (_Bool)n; }'
check bool-runtime-cast-long-long 1 'int main(void) { long long n = -4294967296LL; return (_Bool)n; }'
check bool-runtime-cast-wrapped-unsigned 0 'int main(void) { unsigned n = 4294967295U; return (_Bool)(n + 1); }'
check bool-runtime-cast-from-bool 1 'int main(void) { _Bool b = 256; return (long)b == 1L && (unsigned char)b == 1; }'
check bool-runtime-init-null-pointer 0 'int main(void) { int *p = 0; _Bool b = p; return b; }'
check bool-runtime-init-object-pointer 1 'int main(void) { int n; int *p = &n; _Bool b = p; return b; }'
check bool-runtime-cast-high-pointer 1 'int main(void) { void *p = (void *)4294967296UL; return (_Bool)p; }'
check bool-runtime-init-array 1 'int main(void) { int a[2]; _Bool b = a; return b; }'
check bool-runtime-init-string 1 'int main(void) { _Bool b = ""; return b; }'
check bool-runtime-local-init-byte-width 1 'int main(void) { int guard = 305419896; _Bool b = 256; return guard == 305419896 && b == 1; }'
check bool-runtime-chained-assignment 1 'int main(void) { _Bool a; _Bool b; int r = (a = b = 256); return r == 1 && a == 1 && b == 1; }'
check bool-runtime-assignment-zero-result 0 'int main(void) { _Bool b = 1; return b = 0; }'
check bool-runtime-assignment-pointer 1 'int main(void) { _Bool b = 0; int n; return (b = &n) == 1 && b == 1; }'
check bool-runtime-assignment-null-pointer 1 'int main(void) { _Bool b = 1; int *p = 0; return (b = p) == 0 && b == 0; }'
check bool-runtime-array-byte-access 1 'int main(void) { _Bool a[3]; a[0] = 1; a[1] = 1; a[2] = 1; a[1] = 0; return a[0] + 2*a[1] + 4*a[2] == 5; }'
check bool-runtime-member-byte-access 1 'int main(void) { struct S { _Bool a; unsigned char c; _Bool b; unsigned char d; }; struct S s; s.c = 123; s.d = 45; s.a = 256; s.b = 0; s.a++; s.b--; return s.c == 123 && s.d == 45 && s.a == 1 && s.b == 1; }'
check bool-runtime-arrow-compound-assignment 1 'int main(void) { struct S { _Bool b; int n; }; struct S s; struct S *p = &s; p->n = 42; p->b = 256; p->b += 255; return p->b == 1 && p->n == 42; }'
check bool-runtime-pointer-load-store 1 'int main(void) { _Bool b = 0; _Bool *p = &b; *p = 256; return *p; }'
check bool-runtime-signed-integer-promotion 1 'int main(void) { _Bool b = 1; return -b == -1 && ~b == -2 && b + b == 2; }'
check bool-runtime-integer-operations 1 'int main(void) { _Bool b = 1; return b << 8 == 256 && b / 2 == 0 && b % 2 == 1; }'
check bool-runtime-conditions 1 'int main(void) { _Bool b = 1; int n = 0; if (b) n++; while (b) { n++; b = 0; } return n == 2; }'
check bool-runtime-switch-promotion 1 'int main(void) { _Bool b = 1; switch(b) { case 1: return 1; default: return 0; } }'
check bool-runtime-short-circuit 1 'int main(void) { _Bool a = 0; _Bool b = 1; int n = 0; a && ++n; b || ++n; return n == 0 && (a ? a : b) == 1; }'
check bool-runtime-conversion-side-effect-once 1 'int count; long next(void) { count++; return 1L << 40; } int main(void) { _Bool b = next(); return b == 1 && count == 1; }'
check bool-runtime-global-zero-load 0 '_Bool b; int main(void) { return b; }'
check bool-runtime-global-nonzero-load 1 '_Bool b = 256; int main(void) { return b; }'
check bool-runtime-global-update-representation 1 '_Bool b; int main(void) { b = 256; b += 255; return b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-pointer-arithmetic 1 '_Bool b = 1; int main(void) { _Bool *p = &b; return p + 1 - p == 1 && sizeof(*p) == 1 && *p == 1; }'
check bool-runtime-function-return 1 '_Bool f(long n) { return n; } int main(void) { return f(1L << 40) == 1 && f(0) == 0; }'
check bool-runtime-function-pointer-return 1 '_Bool f(void *p) { return p; } int main(void) { return f((void *)4294967296UL) == 1 && f((void *)0) == 0; }'
check bool-runtime-function-argument 1 'int f(_Bool b) { return b; } int main(void) { return f(256); }'
check bool-runtime-function-parameter-update 1 '_Bool f(_Bool b) { b += 255; return b; } int main(void) { return f(0) == 1 && f(1) == 1; }'
check bool-runtime-six-register-arguments 21 'int f(_Bool a,_Bool b,_Bool c,_Bool d,_Bool e,_Bool f) { return a + 2*b + 4*c + 8*d + 16*e + 32*f; } int main(void) { return f(256,0,-1,0,4294967296UL,0); }'
check bool-runtime-stack-arguments 85 'int f(_Bool a,_Bool b,_Bool c,_Bool d,_Bool e,_Bool f,_Bool g,_Bool h) { return a+2*b+4*c+8*d+16*e+32*f+64*g+128*h; } int main(void) { return f(256,0,-1,0,4294967296UL,0,65536,0); }'
check bool-runtime-mixed-stack-arguments 1 'int f(int a,long b,char c,_Bool d,short e,int f,_Bool g,_Bool h) { g += 255; h--; return a==3 && b==4294967296L && c==-1 && d==1 && e==7 && f==9 && g==1 && h==1; } int main(void) { return f(3,4294967296L,-1,256,7,9,256,0); }'
check bool-runtime-nested-calls 1 '_Bool f(_Bool b) { return b; } int main(void) { return f(f(256)); }'
check bool-runtime-default-argument-promotion 1 'int f(); int main(void) { return f((_Bool)256); } int f(int b) { return b; }'
check bool-runtime-increment-address-once 1 'int calls; _Bool *target(_Bool *p) { calls++; return p; } int main(void) { _Bool b = 1; int old = (*target(&b))++; int new = ++(*target(&b)); return calls==2 && old==1 && new==1 && b==1; }'
check bool-runtime-compound-address-once 1 'int calls; _Bool *target(_Bool *p) { calls++; return p; } int value(void) { calls++; return 256; } int main(void) { _Bool b = 0; int r = (*target(&b) += value()); return calls==2 && r==1 && b==1; }'
check bool-runtime-pre-increment-0 1 'int main(void) { _Bool b = 0; int r = ++b; return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-pre-increment-1 1 'int main(void) { _Bool b = 1; int r = ++b; return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-post-increment-0 1 'int main(void) { _Bool b = 0; int r = b++; return r == 0 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-post-increment-1 1 'int main(void) { _Bool b = 1; int r = b++; return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-pre-decrement-0 1 'int main(void) { _Bool b = 0; int r = --b; return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-pre-decrement-1 1 'int main(void) { _Bool b = 1; int r = --b; return r == 0 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-post-decrement-0 1 'int main(void) { _Bool b = 0; int r = b--; return r == 0 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-post-decrement-1 1 'int main(void) { _Bool b = 1; int r = b--; return r == 1 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-compound-add-1-255 1 'int main(void) { _Bool b = 1; int r = (b += 255); return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-compound-add-1-4294967295U 1 'int main(void) { _Bool b = 1; int r = (b += 4294967295U); return r == 0 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-compound-add-0-4294967296UL 1 'int main(void) { _Bool b = 0; int r = (b += 4294967296UL); return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-compound-sub-0-1 1 'int main(void) { _Bool b = 0; int r = (b -= 1); return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-compound-sub-1-1 1 'int main(void) { _Bool b = 1; int r = (b -= 1); return r == 0 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-compound-mul-1-256 1 'int main(void) { _Bool b = 1; int r = (b *= 256); return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-compound-mul-1-0 1 'int main(void) { _Bool b = 1; int r = (b *= 0); return r == 0 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-compound-div-1-2 1 'int main(void) { _Bool b = 1; int r = (b /= 2); return r == 0 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-compound-mod-1-2 1 'int main(void) { _Bool b = 1; int r = (b %= 2); return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-compound-lshift-1-8 1 'int main(void) { _Bool b = 1; int r = (b <<= 8); return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-compound-rshift-1-1 1 'int main(void) { _Bool b = 1; int r = (b >>= 1); return r == 0 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-compound-and-1-2 1 'int main(void) { _Bool b = 1; int r = (b &= 2); return r == 0 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-compound-or-0-256 1 'int main(void) { _Bool b = 0; int r = (b |= 256); return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'
check bool-runtime-compound-xor-1-1 1 'int main(void) { _Bool b = 1; int r = (b ^= 1); return r == 0 && b == 0 && *(unsigned char *)&b == 0; }'
check bool-runtime-compound-xor-1-256 1 'int main(void) { _Bool b = 1; int r = (b ^= 256); return r == 1 && b == 1 && *(unsigned char *)&b == 1; }'

# _Bool frontend: types, promotions, constant conversions and diagnostics.
check bool-sizeof-type 1 'int main(void) { return sizeof(_Bool); }'
check bool-array-size 3 'int main(void) { _Bool a[3]; return sizeof(a); }'
check bool-typedef 1 'typedef _Bool B; typedef _Bool B; int main(void) { B b; return sizeof(b); }'
check bool-typedef-after-type 1 '_Bool typedef B; int main(void) { return sizeof(B); }'
check bool-function-type 1 '_Bool f(_Bool b); int main(void) { return sizeof(f(256)); }'
check bool-pointer-argument 1 '_Bool f(_Bool b); int main(void) { int x; return sizeof(f(&x)); }'
check bool-array-argument 1 '_Bool f(_Bool b); int main(void) { int a[2]; return sizeof(f(a)); }'
check bool-string-argument 1 '_Bool f(_Bool b); int main(void) { return sizeof(f("abc")); }'
check bool-struct-members 1 'struct S { _Bool a; _Bool b; }; int main(void) { return sizeof(struct S) == 2; }'
check bool-struct-alignment 12 'struct S { _Bool a; int i; _Bool b; }; int main(void) { return sizeof(struct S); }'
check bool-pointer-cast-type 1 'int main(void) { int x; return sizeof((_Bool)&x); }'
check bool-string-cast-type 1 'int main(void) { return sizeof((_Bool)"abc"); }'
check bool-arithmetic-promotion 4 'int main(void) { _Bool b; return sizeof(b + b); }'
check bool-bitwise-promotion 4 'int main(void) { _Bool b; return sizeof(~b); }'
check bool-negation-promotion 4 'int main(void) { _Bool b; return sizeof(-b); }'
check bool-shift-promotion 4 'int main(void) { _Bool b; return sizeof(b << b); }'
check bool-conditional-promotion 4 'int main(void) { _Bool b; return sizeof(1 ? b : b); }'
check bool-assignment-type 1 'int main(void) { _Bool b; return sizeof(b = 256); }'
check bool-pointer-assignment 1 'int main(void) { _Bool b; int x; return sizeof(b = &x); }'
check bool-compound-assignment-type 1 'int main(void) { _Bool b; return sizeof(b += 2); }'
check bool-inc-dec-type 1 'int main(void) { _Bool b; return sizeof(++b) + sizeof(b--) == 2; }'
check bool-constant-zero 0 'enum E { A = (_Bool)0 }; int main(void) { return A; }'
check bool-constant-not-truncation 1 'enum E { A = (_Bool)256 }; int main(void) { return A; }'
check bool-constant-negative 1 'enum E { A = (_Bool)-1 }; int main(void) { return A; }'
check bool-constant-unsigned-max 1 'enum E { A = (_Bool)18446744073709551615ULL }; int main(void) { return A; }'
check bool-constant-after-narrowing 0 'enum E { A = (_Bool)(unsigned char)256 }; int main(void) { return A; }'
check bool-constant-array-bound 4 'int main(void) { int a[(_Bool)256]; return sizeof(a); }'
check bool-global-zero 0 'int x; int a[3]; _Bool b = 0; int main(void) { return *(unsigned char *)&b; }'
check bool-global-one 1 'int x; int a[3]; _Bool b = 1; int main(void) { return *(unsigned char *)&b; }'
check bool-global-negative 1 'int x; int a[3]; _Bool b = -256; int main(void) { return *(unsigned char *)&b; }'
check bool-global-wide 1 'int x; int a[3]; _Bool b = 256; int main(void) { return *(unsigned char *)&b; }'
check bool-global-high-bit 1 'int x; int a[3]; _Bool b = 4294967296UL; int main(void) { return *(unsigned char *)&b; }'
check bool-global-unsigned-max 1 'int x; int a[3]; _Bool b = 18446744073709551615ULL; int main(void) { return *(unsigned char *)&b; }'
check bool-global-narrowed 0 'int x; int a[3]; _Bool b = (unsigned char)256; int main(void) { return *(unsigned char *)&b; }'
check bool-global-null 0 'int x; int a[3]; _Bool b = (void *)0; int main(void) { return *(unsigned char *)&b; }'
check bool-global-nonzero-pointer 1 'int x; int a[3]; _Bool b = (int *)256; int main(void) { return *(unsigned char *)&b; }'
check bool-global-high-pointer 1 'int x; int a[3]; _Bool b = (void *)4294967296UL; int main(void) { return *(unsigned char *)&b; }'
check bool-global-address 1 'int x; int a[3]; _Bool b = &x; int main(void) { return *(unsigned char *)&b; }'
check bool-global-array 1 'int x; int a[3]; _Bool b = a; int main(void) { return *(unsigned char *)&b; }'
check bool-global-string 1 'int x; int a[3]; _Bool b = (_Bool)""; int main(void) { return *(unsigned char *)&b; }'
check bool-global-nested-casts 1 'int x; int a[3]; _Bool b = (_Bool)(_Bool)&x; int main(void) { return *(unsigned char *)&b; }'
check bool-global-address-offset 1 'int x; int a[3]; _Bool b = (_Bool)(a + 2); int main(void) { return *(unsigned char *)&b; }'
check bool-global-pointer-conditional 1 'int x; int a[3]; _Bool b = 0 ? (int *)0 : &x; int main(void) { return *(unsigned char *)&b; }'
check_error bool-unsigned 'unsigned _Bool b;' \
            '1:10: error: invalid combination of type specifiers'
check_error bool-unsigned-reversed '_Bool unsigned b;' \
            '1:7: error: invalid combination of type specifiers'
check_error bool-int '_Bool int b;' \
            '1:7: error: invalid combination of type specifiers'
check_error bool-char 'char _Bool b;' \
            '1:6: error: invalid combination of type specifiers'
check_error bool-long 'long _Bool b;' \
            '1:6: error: invalid combination of type specifiers'
check_error bool-short '_Bool short b;' \
            '1:7: error: invalid combination of type specifiers'
check_error bool-duplicate '_Bool _Bool b;' \
            '1:7: error: duplicate _Bool type specifier'
check_error bool-global-type-conflict '_Bool b; unsigned char b;' \
            "1:24: error: conflicting declaration of variable 'b'"
check_error bool-prototype-conflict 'int f(); int f(_Bool b);' \
            "1:14: error: conflicting declaration of function 'f'"
check_error bool-prototype-conflict-reversed 'int f(_Bool b); int f();' \
            "1:21: error: conflicting declaration of function 'f'"
check_error bool-void-init 'void f(void); int main(void) { _Bool b = f(); return 0; }' \
            '1:42: error: void expression used as a value'
check_error bool-struct-init 'struct S { int x; }; int main(void) { struct S s; _Bool b = s; return 0; }' \
            '1:61: error: struct values are not supported yet'
check_error bool-void-cast 'void f(void); int main(void) { return (_Bool)f(); }' \
            '1:46: error: cast operand must have scalar type'
check_error bool-pointer-incompatible 'int main(void) { _Bool b; unsigned char *p = &b; return 0; }' \
            '1:42: error: incompatible initializer type'
check_error bool-nonzero-to-pointer 'int main(void) { int *p = (_Bool)256; return 0; }' \
            '1:23: error: incompatible initializer type'
check_error bool-global-variable-init 'int x; _Bool b = x;' \
            '1:18: error: global initializer is not a constant expression'
check_error bool-global-pointer-variable-init 'int *p; _Bool b = p;' \
            '1:19: error: global initializer is not a constant expression'
check_error bool-address-enumerator 'int x; enum E { A = (_Bool)&x };' \
            '1:31: error: not an integer constant expression'
check_error bool-address-array-bound 'int x; int a[(_Bool)&x];' \
            '1:23: error: not an integer constant expression'

# Explicit casts share AST_CAST with implicit conversions.
check cast-signed-char 1 'int main(void) { return (char)255 == -1; }'
check cast-unsigned-char 1 'int main(void) { return (unsigned char)511 == 255; }'
check cast-signed-short 1 'int main(void) { return (short)65535 == -1; }'
check cast-unsigned-short 1 'int main(void) { return (unsigned short)-1 == 65535; }'
check cast-signed-int 1 'int main(void) { return (int)4294967295U == -1; }'
check cast-unsigned-int 1 'int main(void) { return (unsigned)-1 == 4294967295U; }'
check cast-signed-long 1 'int main(void) { return (long)-1 == -1L; }'
check cast-unsigned-long 1 'int main(void) { return (unsigned long)-1 == 18446744073709551615UL; }'
check cast-signed-long-long 1 'int main(void) { return (long long)-1 == -1LL; }'
check cast-unsigned-long-long 1 'int main(void) { return (unsigned long long)-1 == 18446744073709551615ULL; }'
check cast-signed-widening 1 'int main(void) { return (long)(int)4294967295U == -1L; }'
check cast-unsigned-widening 1 'int main(void) { return (unsigned long)(unsigned)-1 == 4294967295UL; }'
check cast-signed-byte-widening 1 'int main(void) { return (unsigned long)(char)255 == 18446744073709551615UL; }'
check cast-signed-short-widening 1 'int main(void) { return (long long)(short)65535 == -1LL; }'
check cast-nested-right-association 1 'int main(void) { return (char)(unsigned char)511 == -1; }'
check cast-unary-negation 1 'int main(void) { return -(char)255 == 1; }'
check cast-unary-complement 1 'int main(void) { return ~(unsigned char)0 == -1; }'
check cast-unary-not 1 'int main(void) { return !(int *)0 == 1; }'
check cast-multiplication-precedence 1 'int main(void) { return 3 * (unsigned char)257 == 3; }'
check cast-division-precedence 1 'int main(void) { return (int)257 / (char)2 == 128; }'
check cast-parenthesized-operand 1 'int main(void) { return (char)(255 + 2) == 1; }'
check cast-conditional-operand 1 'int main(void) { return (int)(1 ? 42 : 0) == 42; }'
check cast-sizeof-result-type 1 'int main(void) { return sizeof((unsigned char)1000) == 1 && sizeof((long)1) == 8; }'
check cast-typedef-name 42 'typedef unsigned long U; int main(void) { U n = (U)42; return n; }'
check cast-shadowed-typedef-grouping 42 'typedef int T; int main(void) { int T = 42; return (T) + 0; }'
check cast-enum-type 42 'enum E { A = 42 }; int main(void) { enum E e = (enum E)42; return (int)e; }'
check cast-dereference-cast 42 'int main(void) { int x = 42; void *p = &x; return *(int *)p; }'
check cast-pointer-typedef 42 'typedef int *P; int main(void) { int x = 42; void *p = &x; return *((P)p); }'
check cast-unrelated-pointer-types 1 'int main(void) { int x = 42; char *p = (char *)&x; return (int *)p == &x; }'
check cast-pointer-integer-roundtrip 1 'int main(void) { int x = 42; unsigned long n = (unsigned long)&x; int *p = (int *)n; return p == &x && *p == 42; }'
check cast-signed-int-to-pointer 1 'int main(void) { return (unsigned long)(int *)-1 == 18446744073709551615UL; }'
check cast-unsigned-int-to-pointer 1 'int main(void) { return (unsigned long)(int *)4294967295U == 4294967295UL; }'
check cast-signed-char-to-pointer 1 'int main(void) { return (unsigned long)(void *)(char)255 == 18446744073709551615UL; }'
check cast-unsigned-char-to-pointer 1 'int main(void) { return (unsigned long)(void *)(unsigned char)511 == 255UL; }'
check cast-pointer-to-int-truncation 1 'int main(void) { return (int)(void *)4294967338UL == 42; }'
check cast-pointer-to-byte 1 'int main(void) { return (unsigned char)(void *)511 == 255; }'
check cast-array-decay 42 'int main(void) { int a[2]; int *p = (int *)a; p[1] = 42; return a[1]; }'
check cast-object-representation 120 'int main(void) { int x = 305419896; return *(unsigned char *)&x; }'
check cast-string-decay 98 'int main(void) { return ((char *)"abc")[1]; }'
check cast-struct-pointer 42 'int main(void) { struct S { int x; }; struct S s; void *p = &s; ((struct S *)p)->x = 42; return s.x; }'
check cast-void-typedef 42 'int main(void) { typedef void V; int x = 0; (V)(x = 42); return x; }'
check cast-void-side-effect 42 'int main(void) { int x = 41; (void)x++; return x; }'
check cast-void-call 42 'int x; void f(void) { x = 42; } int main(void) { (void)f(); return x; }'
check cast-void-to-void 42 'int main(void) { (void)(void)0; return 42; }'
check cast-discard-struct 42 'int main(void) { struct S { int x; }; struct S s; s.x = 42; (void)s; return 42; }'
check cast-discard-array 42 'int main(void) { char s[] = "abc"; (void)s; return 42; }'
check cast-void-for-expression 42 'int main(void) { int n = 0; for ((void)(n = 42); 0; (void)n++) {} return n; }'
check cast-void-null-conditional-type 1 'int main(void) { int x = 42; return *(1 ? &x : (void *)0) == 42 && *(0 ? (void *)0 : &x) == 42; }'
check cast-cast-argument 42 'int f(int *p) { return *p; } int main(void) { int x = 42; return f((int *)(void *)&x); }'
check cast-cast-return 42 'int *f(void *p) { return (int *)p; } int main(void) { int x = 42; return *f(&x); }'
check cast-global-integer 1 'unsigned long x = (unsigned long)(int)-1; int main(void) { return x == 18446744073709551615UL; }'
check cast-global-narrowing 1 'unsigned char x = (unsigned char)511; int main(void) { return x == 255; }'
check cast-global-numeric-pointer 1 'int *p = (int *)16; int main(void) { return (unsigned long)p == 16; }'
check cast-global-high-pointer-bits 1 'void *p = (void *)18446744073709551615ULL; int main(void) { return (unsigned long)p == 18446744073709551615UL; }'
check cast-global-signed-pointer 1 'int *p = (int *)-1; int main(void) { return (unsigned long)p == 18446744073709551615UL; }'
check cast-global-unsigned-pointer 1 'int *p = (int *)4294967295U; int main(void) { return (unsigned long)p == 4294967295UL; }'
check cast-global-signed-byte-pointer 1 'int *p = (int *)(char)255; int main(void) { return (unsigned long)p == 18446744073709551615UL; }'
check cast-global-void-null 1 'int *p = (void *)0; int main(void) { return p == 0; }'
check cast-global-void-constant-null 1 'int *p = (void *)(1-1); int main(void) { return p == 0; }'
check cast-global-pointer-reinterpretation 42 'int x = 42; char *p = (char *)&x; int main(void) { return *(int *)p; }'
check cast-global-byte-offset 1 'int a[3]; char *p = (char *)a + 4; int main(void) { return (int *)p == &a[1]; }'
check cast-global-member-address 1 'struct S { char c; long n; }; struct S s; char *p = (char *)&s.n; int main(void) { return (long *)p == &s.n; }'
check cast-global-string-pointer 65 'unsigned char *p = (unsigned char *)"A"; int main(void) { return *p; }'
check cast-array-bound 16 'int main(void) { int a[(unsigned char)260]; return sizeof(a); }'
check cast-enum-initializer 255 'enum { N = (unsigned char)511 }; int main(void) { return N; }'
check cast-case-label 42 'int main(void) { switch (255) { case (unsigned char)511: return 42; } return 0; }'
check cast-operand-evaluated-once 1 'int main(void) { int x = 0; return (int)(x = 1) == 1 && x == 1; }'
check_error cast-struct-target 'struct S { int x; }; int main(void) { struct S s; (struct S)s; }' "1:51: error: cast target must be a scalar type or void"
check_error cast-array-target 'int main(void) { (int[3])0; }' "1:18: error: cast target must be a scalar type or void"
check_error cast-typedef-array-target 'typedef int A[3]; int main(void) { (A)0; }' "1:36: error: cast target must be a scalar type or void"
check_error cast-struct-operand 'struct S { int x; }; int main(void) { struct S s; (int)s; }' "1:56: error: cast operand must have scalar type"
check_error cast-void-operand 'void f(void); int main(void) { return (int)f(); }' "1:44: error: cast operand must have scalar type"
check_error cast-same-type-assignment 'int main(void) { int x; (int)x = 1; }' "1:32: error: invalid assignment target"
check_error cast-same-type-address 'int main(void) { int x; &(int)x; }' "1:25: error: invalid address-of target"
check_error cast-same-type-increment 'int main(void) { int x; ((int)x)++; }' "1:33: error: invalid increment target"
check_error cast-pointer-assignment 'int main(void) { int *p; ((int *)p) = 0; }' "1:37: error: invalid assignment target"
check_error cast-void-value 'int main(void) { return (void)42; }' "1:25: error: void expression used as a value"
check_error cast-void-condition 'int main(void) { if ((void)42) return 1; return 0; }' "1:22: error: void expression used as a value"
check_error cast-void-initializer 'int main(void) { int x = (void)42; }' "1:26: error: void expression used as a value"
check_error cast-void-sizeof 'int main(void) { return sizeof((void)42); }' "1:25: error: sizeof cannot be applied to void"
check_error cast-missing-operand 'int main(void) { return (int); }' "1:30: error: expect expr"
check_error cast-missing-close 'int main(void) { return (int 42; }' "1:30: error: expect ')'"
check_error cast-named-type 'int main(void) { return (int x)42; }' "1:30: error: type name cannot contain an identifier"
check_error cast-typedef-storage 'int main(void) { return (typedef int)42; }' "1:26: error: typedef is not allowed here"
check_error cast-implicit-pointer-still-invalid 'int main(void) { int *p = 1; }' "1:23: error: incompatible initializer type"
check_error cast-global-pointer-variable 'int n; int *p = (int *)n;' "1:17: error: global initializer is not a constant expression"
check_error cast-global-integer-from-pointer 'int x; unsigned long n = (unsigned long)&x;' "1:26: error: global initializer is not a constant expression"
check_error cast-global-integer-pointer-roundtrip 'long n = (long)(void *)1;' "1:10: error: global initializer is not a constant expression"
check_error cast-pointer-cast-array-bound 'int a[(int)(void *)1];' "1:21: error: not an integer constant expression"
check_error cast-pointer-cast-enumerator 'enum { A = (int)(void *)1 };' "1:27: error: not an integer constant expression"
check_error cast-pointer-cast-case 'int main(void) { switch (1) { case (int)(void *)1: return 0; } }' "1:50: error: not an integer constant expression"

# Stack layout visits declarations after parsing each complete function.
check stack-layout-nested-block 42 'int main(void) { { char s[] = "abc"; long n = 42; return s[3] + n; } }'
check stack-layout-if-and-else 42 'int main(void) { int n = 0; if (n) { char a[] = "a"; n = a[0]; } else { char b[] = "b"; long x = 42; n = x + b[1]; } return n; }'
check stack-layout-while-body 42 'int main(void) { int n = 0; while (n < 42) { char a[16] = "abc"; long x = 1; n += x + a[15]; } return n; }'
check stack-layout-for-init-and-body 42 'int main(void) { int n = 0; for (char a[] = "abc"; n < 42; n++) { short b = 42; if (a[3] || b != 42) return 0; } return n; }'
check stack-layout-do-body 42 'int main(void) { int n = 0; do { char a[] = "abc"; long x = 42; n = x + a[3]; } while (0); return n; }'
check stack-layout-switch-cases 42 'int main(void) { switch (2) { case 1: { char a[] = "a"; return a[0]; } case 2: { char b[8] = "abc"; long x = 42; return x + b[7]; } default: { short n = 0; return n; } } return 0; }'
check stack-layout-stacked-cases 42 'int main(void) { switch (2) { case 1: case 2: { char a[] = "abc"; long x = 42; return x + a[3]; } } return 0; }'
check stack-layout-label-body 42 'int main(void) { goto label; label: { char a[16] = "abc"; long x = 42; return x + a[15]; } }'
check stack-layout-declaration-only-nodes 42 'int main(void) { typedef char A[]; struct S { long x; }; enum E { N = 42 }; A a = "abc"; struct S s; s.x = N; return s.x + a[3]; }'
check stack-layout-parameter-homes-and-locals 42 'long f(char a,short b,int c,long d,char e,short f,int g,long h) { char s[] = "abc"; long x = a+b+c+d+e+f+g+h; return x+s[3]; } int main(void) { return f(1,2,3,4,5,6,7,14); }'
check stack-layout-separate-function-frames 42 'int f(int n) { char a[16] = "abc"; if (n) return f(n-1) + a[15]; return 42; } int g(void) { short n = 7; return n; } int main(void) { return f(g()); }'
check stack-layout-maximum-aligned-frame 42 'int huge(void) { char a[2147483632]; return 0; } int main(void) { return 42; }'
check stack-layout-maximum-frame-with-parameters 42 'int huge(int a,int b,int c,int d,int e,int f,int g,int h) { char buffer[2147483568]; return 0; } int main(void) { return 42; }'
check_error stack-layout-second-function-overflow 'int first(void) { return 42; } int second(void) { char a[2147483647]; return 0; }' "1:56: error: local variables exceed supported stack size"
check_error stack-layout-parameter-and-local-overflow 'int f(int a,int b,int c,int d,int e,int f,int g,int h) { char buffer[2147483569]; return 0; }' "1:63: error: local variables exceed supported stack size"
check_error stack-layout-alignment-overflow 'int f(void) { char a[2147483625]; long b; return 0; }' "1:40: error: local variables exceed supported stack size"
check_error stack-layout-for-init-overflow 'int f(void) { for (char a[2147483647]; 0;) {} return 0; }' "1:25: error: local variables exceed supported stack size"
check_error stack-layout-unreachable-branch-overflow 'int f(void) { if (0) { char a[2147483647]; } return 0; }' "1:29: error: local variables exceed supported stack size"
check_error stack-layout-switch-no-double-allocation 'int f(void) { switch (0) { case 0: { char a[1073741816]; } case 1: { char b[1073741817]; } } return 0; }' "1:75: error: local variables exceed supported stack size"

# Character arrays initialized by strings, with inferred or explicit bounds.
check string-array-local-char-inferred 1 'int main(void) { char a[] = "abc"; return sizeof(a) == 4 && a[0] == 97 && a[2] == 99 && a[3] == 0; }'
check string-array-local-char-exact 1 'int main(void) { char a[3] = "abc"; return sizeof(a) == 3 && a[0] == 97 && a[2] == 99; }'
check string-array-local-char-terminated 1 'int main(void) { char a[4] = "abc"; return a[2] == 99 && a[3] == 0; }'
check string-array-local-char-padding 1 'int main(void) { char a[16] = "abc"; for (int i = 3; i < 16; i++) if (a[i]) return 0; return a[0] == 97; }'
check string-array-local-unsigned-char-inferred 1 'int main(void) { unsigned char a[] = "abc"; return sizeof(a) == 4 && a[0] == 97 && a[2] == 99 && a[3] == 0; }'
check string-array-local-unsigned-char-exact 1 'int main(void) { unsigned char a[3] = "abc"; return sizeof(a) == 3 && a[0] == 97 && a[2] == 99; }'
check string-array-local-unsigned-char-terminated 1 'int main(void) { unsigned char a[4] = "abc"; return a[2] == 99 && a[3] == 0; }'
check string-array-local-unsigned-char-padding 1 'int main(void) { unsigned char a[16] = "abc"; for (int i = 3; i < 16; i++) if (a[i]) return 0; return a[0] == 97; }'
check string-array-local-empty-inferred 1 'int main(void) { char a[] = ""; return sizeof(a) == 1 && a[0] == 0; }'
check string-array-local-empty-padded 1 'int main(void) { char a[8] = ""; for (int i = 0; i < 8; i++) if (a[i]) return 0; return 1; }'
check string-array-local-concatenated 1 'int main(void) { char a[] = "ab" "cd"; return sizeof(a) == 5 && a[3] == 100 && a[4] == 0; }'
check string-array-local-embedded-zero 1 'int main(void) { char a[] = "A\0B"; return sizeof(a) == 4 && a[0] == 65 && a[1] == 0 && a[2] == 66 && a[3] == 0; }'
check string-array-local-embedded-zero-exact 1 'int main(void) { char a[3] = "A\0B"; return sizeof(a) == 3 && a[1] == 0 && a[2] == 66; }'
check string-array-local-all-zero-string 1 'int main(void) { char a[8] = "\0\0"; for (int i = 0; i < 8; i++) if (a[i]) return 0; return 1; }'
check string-array-local-signed-bytes 1 'int main(void) { char a[] = "\377\200"; return a[0] == -1 && a[1] == -128 && a[2] == 0; }'
check string-array-local-unsigned-bytes 1 'int main(void) { unsigned char a[] = "\377\200"; return a[0] == 255 && a[1] == 128 && a[2] == 0; }'
check string-array-local-braced 1 'int main(void) { char a[] = {"abc"}; return sizeof(a) == 4 && a[2] == 99 && a[3] == 0; }'
check string-array-local-braced-trailing-comma 1 'int main(void) { char a[8] = {"ab" "cd",}; return a[3] == 100 && a[4] == 0 && a[7] == 0; }'
check string-array-local-long-string 1 'int main(void) { char a[] = "123456789abcdefg123456789abcdefgZ"; return sizeof(a) == 34 && a[32] == 90 && a[33] == 0; }'
check string-array-local-writable 1 'int main(void) { char a[] = "abc"; a[0] = 42; return a[0] == 42 && a[1] == 98; }'
check string-array-local-decay-and-store 1 'int main(void) { char a[] = "abc"; char *p = a; p[1] = 42; return a[1] == 42; }'
check string-array-global-char-inferred 1 'char a[] = "abc"; int main(void) { return sizeof(a) == 4 && a[0] == 97 && a[2] == 99 && a[3] == 0; }'
check string-array-global-char-exact 1 'char a[3] = "abc"; int main(void) { return sizeof(a) == 3 && a[0] == 97 && a[2] == 99; }'
check string-array-global-char-terminated 1 'char a[4] = "abc"; int main(void) { return a[2] == 99 && a[3] == 0; }'
check string-array-global-char-padding 1 'char a[16] = "abc"; int main(void) { for (int i = 3; i < 16; i++) if (a[i]) return 0; return a[0] == 97; }'
check string-array-global-unsigned-char-inferred 1 'unsigned char a[] = "abc"; int main(void) { return sizeof(a) == 4 && a[0] == 97 && a[2] == 99 && a[3] == 0; }'
check string-array-global-unsigned-char-exact 1 'unsigned char a[3] = "abc"; int main(void) { return sizeof(a) == 3 && a[0] == 97 && a[2] == 99; }'
check string-array-global-unsigned-char-terminated 1 'unsigned char a[4] = "abc"; int main(void) { return a[2] == 99 && a[3] == 0; }'
check string-array-global-unsigned-char-padding 1 'unsigned char a[16] = "abc"; int main(void) { for (int i = 3; i < 16; i++) if (a[i]) return 0; return a[0] == 97; }'
check string-array-global-empty-inferred 1 'char a[] = ""; int main(void) { return sizeof(a) == 1 && a[0] == 0; }'
check string-array-global-empty-padded 1 'char a[8] = ""; int main(void) { for (int i = 0; i < 8; i++) if (a[i]) return 0; return 1; }'
check string-array-global-concatenated 1 'char a[] = "ab" "cd"; int main(void) { return sizeof(a) == 5 && a[3] == 100 && a[4] == 0; }'
check string-array-global-embedded-zero 1 'char a[] = "A\0B"; int main(void) { return sizeof(a) == 4 && a[0] == 65 && a[1] == 0 && a[2] == 66 && a[3] == 0; }'
check string-array-global-embedded-zero-exact 1 'char a[3] = "A\0B"; int main(void) { return sizeof(a) == 3 && a[1] == 0 && a[2] == 66; }'
check string-array-global-all-zero-string 1 'char a[8] = "\0\0"; int main(void) { for (int i = 0; i < 8; i++) if (a[i]) return 0; return 1; }'
check string-array-global-signed-bytes 1 'char a[] = "\377\200"; int main(void) { return a[0] == -1 && a[1] == -128 && a[2] == 0; }'
check string-array-global-unsigned-bytes 1 'unsigned char a[] = "\377\200"; int main(void) { return a[0] == 255 && a[1] == 128 && a[2] == 0; }'
check string-array-global-braced 1 'char a[] = {"abc"}; int main(void) { return sizeof(a) == 4 && a[2] == 99 && a[3] == 0; }'
check string-array-global-braced-trailing-comma 1 'char a[8] = {"ab" "cd",}; int main(void) { return a[3] == 100 && a[4] == 0 && a[7] == 0; }'
check string-array-global-long-string 1 'char a[] = "123456789abcdefg123456789abcdefgZ"; int main(void) { return sizeof(a) == 34 && a[32] == 90 && a[33] == 0; }'
check string-array-global-writable 1 'char a[] = "abc"; int main(void) { a[0] = 42; return a[0] == 42 && a[1] == 98; }'
check string-array-global-decay-and-store 1 'char a[] = "abc"; int main(void) { char *p = a; p[1] = 42; return a[1] == 42; }'
check string-array-typedef-inferred-independent-bounds 1 'typedef char A[]; A a = "abc"; A b = "x"; int main(void) { A c = "hello"; return sizeof(a) == 4 && sizeof(b) == 2 && sizeof(c) == 6; }'
check string-array-typedef-fixed-bounds 1 'typedef unsigned char A[8]; A a = "abc"; int main(void) { A b = "x"; return sizeof(a) == 8 && sizeof(b) == 8 && a[7] == 0 && b[7] == 0; }'
check string-array-global-initializer-after-pointer 42 'char a[]; char *p = a; char a[] = "abc"; int main(void) { p[1] = 42; return a[1]; }'
check string-array-global-composite-bound-before-initializer 1 'char a[]; char a[8]; char a[] = "abc"; int main(void) { return sizeof(a) == 8 && a[2] == 99 && a[7] == 0; }'
check string-array-global-repeated-unknown-bound 1 'char a[8]; char a[] = "abc"; char a[]; int main(void) { return sizeof(a) == 8 && a[7] == 0; }'
check string-array-global-compatible-known-bound 1 'char a[] = "abc"; char a[4]; int main(void) { return sizeof(a) == 4 && a[3] == 0; }'
check string-array-global-multiple-arrays 1 'char a[] = "abc", b[8] = "x", c[] = "yz"; int main(void) { return sizeof(a) == 4 && sizeof(b) == 8 && sizeof(c) == 3 && b[7] == 0; }'
check string-array-global-array-and-pointer 1 'char a[] = "abc", *p = a + 1; int main(void) { return p[0] == 98 && p[2] == 0; }'
check string-array-array-and-literal-independent 1 'char a[] = "abc"; char *p = "abc"; int main(void) { a[0] = 42; return p[0] == 97 && a[0] == 42; }'
check string-array-local-independent-copies 1 'int main(void) { char a[] = "abc"; char b[] = "abc"; a[0] = 42; return b[0] == 97 && a[0] == 42; }'
check string-array-unknown-bound-parameter 42 'int f(char a[]) { a[0] = 42; return a[0]; } int main(void) { char a[] = "abc"; return f(a); }'
check string-array-local-neighbor-layout 1 'int main(void) { long x = 1099511627776L; char a[3] = "abc"; long y = 1099511627777L; return a[2] == 99 && x == 1099511627776L && y == 1099511627777L; }'
check string-array-for-initializer 1 'int main(void) { for (char a[] = "abc"; a[0] != 42; a[0] = 42) { if (a[3]) return 0; } return 1; }'
check string-array-local-reinitialization 1 'int main(void) { for (int i = 0; i < 3; i++) { char a[64] = "abc"; if (a[0] != 97 || a[63]) return 0; a[0] = 1; a[63] = 1; } return 1; }'
check string-array-recursive-local-storage 1 'int f(int n) { char a[16] = "abc"; a[0] = n; if (n) f(n - 1); return a[0] == n && a[15] == 0; } int main(void) { return f(3); }'
check string-array-local-with-eight-parameters 1 'int f(int a,int b,int c,int d,int e,int f,int g,int h) { char s[32] = "abc"; return a+b+c+d+e+f+g+h == 36 && s[0] == 97 && s[31] == 0; } int main(void) { return f(1,2,3,4,5,6,7,8); }'
check string-array-large-local-padding 1 'int main(void) { char a[4096] = "abc"; for (int i = 3; i < 4096; i++) if (a[i]) return 0; return a[2] == 99; }'
check string-array-large-global-padding 1 'char a[4096] = "abc"; int main(void) { for (int i = 3; i < 4096; i++) if (a[i]) return 0; return a[2] == 99; }'
check string-array-interleaved-sections 42 'char a[] = "A"; int f(void) { char b[] = "B"; return b[0] - a[0]; } char z[8] = ""; char *p = "C"; int x = 40; int main(void) { return x + f() + z[7] + p[0] - 66; }'
check string-array-tentative-unknown-bound 1 'char a[]; int main(void) { return a[0] == 0; }'
check string-array-tentative-typedef-independent-bound 1 'typedef char A[]; A a; A b = "abc"; int main(void) { return a[0] == 0 && sizeof(b) == 4; }'
check_error string-array-local-too-long 'int main(void) { char a[2] = "abc"; return 0; }' "1:30: error: string literal is too long for character array"
check_error string-array-local-concat-too-long 'int main(void) { char a[2] = "ab" "cd"; return 0; }' "1:30: error: string literal is too long for character array"
check_error string-array-local-embedded-zero-too-long 'int main(void) { char a[2] = "A\0B"; return 0; }' "1:30: error: string literal is too long for character array"
check_error string-array-local-unsigned-too-long 'int main(void) { unsigned char a[1] = "ab"; return 0; }' "1:39: error: string literal is too long for character array"
check_error string-array-local-integer-elements 'int main(void) { int a[] = "abc"; return 0; }' "1:28: error: string initializer requires a character array"
check_error string-array-local-pointer-elements 'int main(void) { char *a[] = "abc"; return 0; }' "1:30: error: string initializer requires a character array"
check_error string-array-local-pointer-source 'int main(void) { char *p; char a[] = p; return 0; }' "1:38: error: character array initializer must be a string literal"
check_error string-array-local-pointer-expression 'int main(void) { char a[] = "abc" + 1; return 0; }' "1:35: error: character array initializer must be a string literal"
check_error string-array-local-integer-source 'int main(void) { char a[] = 0; return 0; }' "1:29: error: character array initializer must be a string literal"
check_error string-array-local-conditional-source 'int main(void) { char a[] = 1 ? "a" : "b"; return 0; }' "1:31: error: character array initializer must be a string literal"
check_error string-array-local-extra-string 'int main(void) { char a[] = {"a", "b"}; return 0; }' "1:35: error: expect '}'"
check_error string-array-local-missing-rbrace 'int main(void) { char a[] = {"a"; return 0; }' "1:33: error: expect '}'"
check_error string-array-global-too-long 'char a[2] = "abc";' "1:13: error: string literal is too long for character array"
check_error string-array-global-concat-too-long 'char a[2] = "ab" "cd";' "1:13: error: string literal is too long for character array"
check_error string-array-global-embedded-zero-too-long 'char a[2] = "A\0B";' "1:13: error: string literal is too long for character array"
check_error string-array-global-unsigned-too-long 'unsigned char a[1] = "ab";' "1:22: error: string literal is too long for character array"
check_error string-array-global-integer-elements 'int a[] = "abc";' "1:11: error: string initializer requires a character array"
check_error string-array-global-pointer-elements 'char *a[] = "abc";' "1:13: error: string initializer requires a character array"
check_error string-array-global-pointer-source 'char *p; char a[] = p;' "1:21: error: character array initializer must be a string literal"
check_error string-array-global-pointer-expression 'char a[] = "abc" + 1;' "1:18: error: character array initializer must be a string literal"
check_error string-array-global-integer-source 'char a[] = 0;' "1:12: error: character array initializer must be a string literal"
check_error string-array-global-conditional-source 'char a[] = 1 ? "a" : "b";' "1:14: error: character array initializer must be a string literal"
check_error string-array-global-extra-string 'char a[] = {"a", "b"};' "1:18: error: expect '}'"
check_error string-array-global-missing-rbrace 'char a[] = {"a";' "1:16: error: expect '}'"
check_error string-array-global-redefinition 'char a[] = "abc"; char a[] = "x";' "1:24: error: redefinition of variable 'a'"
check_error string-array-global-zero-redefinition 'char a[8] = ""; char a[8] = "";' "1:22: error: redefinition of variable 'a'"
check_error string-array-global-conflicting-bound 'char a[] = "abc"; char a[5];' "1:24: error: conflicting declaration of variable 'a'"
check_error string-array-global-known-bound-too-small 'char a[2]; char a[] = "abc";' "1:23: error: string literal is too long for character array"
check_error string-array-incomplete-sizeof-type 'int main(void) { return sizeof(char[]); }' "1:25: error: sizeof cannot be applied to an incomplete type"
check_error string-array-typedef-bound-stays-incomplete 'typedef char A[]; A a = "abc"; int main(void) { return sizeof(A); }' "1:56: error: sizeof cannot be applied to an incomplete type"
check_error string-array-local-self-sizeof 'int main(void) { char a[] = sizeof(a); }' "1:29: error: sizeof cannot be applied to an incomplete type"
check_error string-array-flexible-member-unsupported 'struct S { char a[]; };' "1:17: error: member has incomplete type"

# Global pointer addresses are emitted as relocations with byte offsets.
check global-pointer-integer-address 42 'int x = 42; int *p = &x; int main(void) { return *p; }'
check global-pointer-char-address 1 'char x = -1; char *p = &x; int main(void) { return *p == -1; }'
check global-pointer-unsigned-char-address 1 'unsigned char x = 255; unsigned char *p = &x; int main(void) { return *p == 255; }'
check global-pointer-short-address 1 'short x = -32768; short *p = &x; int main(void) { return *p == -32768; }'
check global-pointer-unsigned-short-address 1 'unsigned short x = 65535; unsigned short *p = &x; int main(void) { return *p == 65535; }'
check global-pointer-unsigned-address 1 'unsigned x = 4294967295U; unsigned *p = &x; int main(void) { return *p == 4294967295U; }'
check global-pointer-long-address 1 'long x = 1099511627776L; long *p = &x; int main(void) { return *p == 1099511627776L; }'
check global-pointer-unsigned-long-long-address 1 'unsigned long long x = 18446744073709551615ULL; unsigned long long *p = &x; int main(void) { return *p == 18446744073709551615ULL; }'
check global-pointer-enum-address 42 'enum E { ANSWER = 42 }; enum E x = ANSWER; enum E *p = &x; int main(void) { return *p; }'
check global-pointer-void-address 42 'int x = 42; void *p = &x; int main(void) { int *q = p; return *q; }'
check global-pointer-pointer-object-address 42 'int x = 42, *p = &x, **q = &p; int main(void) { return **q; }'
check global-pointer-self-address 1 'void *p = &p; int main(void) { return p == &p; }'
check global-pointer-typedef-address 42 'typedef int I; I x = 42; I *p = &x; int main(void) { return *p; }'
check global-pointer-array-decay-initializer 42 'int a[4]; int *p = a; int main(void) { a[0] = 42; return *p; }'
check global-pointer-array-element-address 42 'int a[4]; int *p = &a[2]; int main(void) { *p = 42; return a[2]; }'
check global-pointer-reversed-add-initializer 42 'int a[4]; int *p = 2 + a; int main(void) { a[2] = 42; return *p; }'
check global-pointer-one-past-initializer 4 'int a[4]; int *p = a + 4; int main(void) { return p - a; }'
check global-pointer-folded-offset-initializer 42 'int a[4]; int *p = a + 3 - 2; int main(void) { a[1] = 42; return *p; }'
check global-pointer-reversed-subscript-initializer 42 'int a[4]; int *p = &2[a]; int main(void) { a[2] = 42; return *p; }'
check global-pointer-address-deref-initializer 42 'int a[4]; int *p = &*(a + 2); int main(void) { a[2] = 42; return *p; }'
check global-pointer-byte-offset-initializer 42 'char a[4]; char *p = a + 2; int main(void) { a[2] = 42; return *p; }'
check global-pointer-short-offset-initializer 42 'short a[4]; short *p = a + 2; int main(void) { a[2] = 42; return *p; }'
check global-pointer-long-offset-initializer 1 'long a[4]; long *p = a + 2; int main(void) { a[2] = 1099511627776L; return *p == 1099511627776L; }'
check global-pointer-member-address 42 'struct S { char c; long n; }; struct S s; long *p = &s.n; int main(void) { s.n = 42; return *p; }'
check global-pointer-arrow-member-address 42 'struct S { char c; long n; }; struct S s; long *p = &(&s)->n; int main(void) { s.n = 42; return *p; }'
check global-pointer-nested-member-address 42 'struct I { char c; short n; }; struct O { char c; struct I i; }; struct O s; short *p = &s.i.n; int main(void) { s.i.n = 42; return *p; }'
check global-pointer-array-member-decay 42 'struct S { char c; int a[3]; }; struct S s; int *p = s.a + 2; int main(void) { s.a[2] = 42; return *p; }'
check global-pointer-struct-array-member-address 42 'struct S { char c; long n; }; struct S a[3]; long *p = &a[2].n; int main(void) { a[2].n = 42; return *p; }'
check global-pointer-completed-struct-address 42 'struct S; struct S s; struct S *p = &s; struct S { int n; }; int main(void) { p->n = 42; return s.n; }'
check global-pointer-string-initializer 101 'char *p = "hello"; int main(void) { return p[1]; }'
check global-pointer-empty-string-initializer 0 'char *p = ""; int main(void) { return p[0]; }'
check global-pointer-concatenated-string-initializer 1 'char *p = "he" "llo"; int main(void) { return p[4] == 111 && p[5] == 0; }'
check global-pointer-embedded-zero-string-initializer 1 'char *p = "A\0B"; int main(void) { return p[0] == 65 && p[1] == 0 && p[2] == 66 && p[3] == 0; }'
check global-pointer-escaped-byte-string-initializer 1 'char *p = "\377B"; int main(void) { return p[0] == -1 && p[1] == 66 && p[2] == 0; }'
check global-pointer-string-full-byte-line 1 'char *p = "123456789abcdef"; int main(void) { return p[14] == 102 && p[15] == 0; }'
check global-pointer-string-next-byte-line 1 'char *p = "123456789abcdefg"; int main(void) { return p[15] == 103 && p[16] == 0; }'
check global-pointer-string-multiple-byte-lines 1 'char *p = "123456789abcdefg123456789abcdefgZ"; int main(void) { return p[32] == 90 && p[33] == 0; }'
check global-pointer-string-offset-initializer 108 'char *p = "hello" + 2; int main(void) { return *p; }'
check global-pointer-string-subscript-initializer 111 'char *p = &"hello"[4]; int main(void) { return *p; }'
check global-pointer-void-string-initializer 65 'void *p = "A"; int main(void) { char *q = p; return *q; }'
check global-pointer-multiple-string-initializers 133 'char *p = "AB", *q = "CD"; int main(void) { return p[0] + q[1]; }'
check global-pointer-conditional-address-initializer 42 'int x = 42; int *p = 1 ? &x : 0; int main(void) { return *p; }'
check global-pointer-unevaluated-call-address-initializer 42 'int *f(void); int x = 42; int *p = 1 ? &x : f(); int main(void) { return *p; }'
check global-pointer-address-tentative-definition 42 'int x = 42; int *p; int *p = &x; int *p; int main(void) { return *p; }'
check global-pointer-initializer-after-function-reference 42 'int x = 42; int *p; int *f(void) { return p; } int *p = &x; int main(void) { return *f(); }'
check global-pointer-later-object-definition 42 'int x; int *p = &x; int x = 42; int main(void) { return *p; }'
check global-pointer-initialized-pointer-writable 42 'int x = 10, y = 42; int *p = &x; int main(void) { p = &y; return *p; }'
check global-pointer-initialized-target-writable 42 'int x = 0; int *p = &x; int main(void) { *p = 42; return x; }'
check global-pointer-data-bss-rodata-text-sections 42 'char *p = "A"; int z; int f(void) { char *q = "B"; return q[0] - p[0]; } char *r = "C"; int x = 40; int main(void) { return x + z + f() + r[0] - 66; }'

# Null pointer initializers and constant-expression diagnostics.
check global-pointer-null-initializer 1 'int *p = 0; int main(void) { return p == 0; }'
check global-void-pointer-null-initializer 1 'void *p = 0; int main(void) { return p == 0; }'
check global-pointer-to-pointer-null-initializer 1 'int **p = 0; int main(void) { return p == 0; }'
check global-incomplete-pointer-null-initializer 1 'struct S; struct S *p = 0; int main(void) { return p == 0; }'
check global-pointer-constant-null-initializer 1 'int *p = 1 - 1; int main(void) { return p == 0; }'
check global-pointer-unsigned-null-initializer 1 'int *p = 0ULL; int main(void) { return p == 0; }'
check global-pointer-enum-null-initializer 1 'enum { ZERO }; int *p = ZERO; int main(void) { return p == 0; }'
check global-pointer-typedef-null-initializer 1 'typedef int *P; P p = 0; int main(void) { return p == 0; }'
check global-pointer-null-tentative-definition 1 'int *p; int *p = 0; int *p; int main(void) { return p == 0; }'
check global-pointer-null-conditional-initializer 1 'int x; int *p = 0 ? &x : 0; int main(void) { return p == 0; }'
check global-pointer-null-unevaluated-call 1 'int *f(void); int *p = 0 ? f() : 0; int main(void) { return p == 0; }'
check global-pointer-null-address-deref 1 'int x; int *p = &*(0 ? &x : 0); int main(void) { return p == 0; }'
check global-pointer-null-then-store 42 'int x = 42; int *p = 0; int main(void) { p = &x; return *p; }'
check_error global-initializer-nonzero-integer 'int *p = 1;' "1:6: error: incompatible initializer type"
check_error global-initializer-incompatible-pointer 'long x; int *p = &x;' "1:14: error: incompatible initializer type"
check_error global-initializer-incompatible-string 'unsigned char *p = "A";' "1:16: error: incompatible initializer type"
check_error global-initializer-pointer-read 'int *q; int *p = q;' "1:18: error: global initializer is not a constant expression"
check_error global-initializer-initialized-pointer-read 'int x; int *q = &x; int *p = q;' "1:30: error: global initializer is not a constant expression"
check_error global-initializer-null-pointer-read 'int *q = 0; int *p = q;' "1:22: error: global initializer is not a constant expression"
check_error global-initializer-pointer-self-read 'int *p = p;' "1:10: error: global initializer is not a constant expression"
check_error global-initializer-pointer-call 'int *f(void); int *p = f();' "1:24: error: global initializer is not a constant expression"
check_error global-initializer-pointer-dereference 'int **q; int *p = *q;' "1:19: error: global initializer is not a constant expression"
check_error global-initializer-pointer-member-read 'struct S { int *p; }; struct S s; int *p = s.p;' "1:45: error: global initializer is not a constant expression"
check_error global-initializer-pointer-arrow-read 'struct S { int n; }; struct S *q; int *p = &q->n;' "1:44: error: global initializer is not a constant expression"
check_error global-initializer-dynamic-offset 'int a[4], n; int *p = a + n;' "1:25: error: global initializer is not a constant expression"
check_error global-initializer-dynamic-subscript 'int a[4], n; int *p = &a[n];' "1:23: error: global initializer is not a constant expression"
check_error global-initializer-offset-call 'int f(void); int a[4]; int *p = a + f();' "1:35: error: global initializer is not a constant expression"
check_error global-initializer-pointer-assignment 'int x, *q; int *p = (q = &x);' "1:24: error: global initializer is not a constant expression"
check_error global-initializer-pointer-increment 'int *q; int *p = q++;' "1:19: error: global initializer is not a constant expression"
check_error global-initializer-pointer-comma 'int x; int *p = (0, &x);' "1:19: error: global initializer is not a constant expression"
check_error global-initializer-dynamic-condition 'int n, x; int *p = n ? &x : 0;' "1:22: error: global initializer is not a constant expression"
check_error global-initializer-evaluated-pointer-call 'int *f(void); int x; int *p = 1 ? f() : &x;' "1:33: error: global initializer is not a constant expression"
check_error global-initializer-pointer-zero-redefinition 'int *p = 0; int *p = 0;' "1:18: error: redefinition of variable 'p'"
check_error global-initializer-pointer-address-redefinition 'int x; int *p = &x; int *p = &x;' "1:26: error: redefinition of variable 'p'"
check_error global-initializer-pointer-scaled-offset-overflow 'long a[2]; long *p = a + 9223372036854775807L;' "1:24: error: address offset exceeds supported range"
check_error global-initializer-pointer-unsigned-offset-overflow 'char a[2]; char *p = a + 18446744073709551615ULL;' "1:24: error: address offset exceeds supported range"
check_error global-initializer-pointer-total-offset-overflow 'char a[2]; char *p = a + 9223372036854775807L + 1;' "1:47: error: address offset exceeds supported range"
check_error global-initializer-pointer-sub-offset-overflow 'char a[2]; char *p = a - (-9223372036854775807L - 1);' "1:24: error: address offset exceeds supported range"
check_error global-initializer-pointer-negative-offset-overflow 'long a[2]; long *p = a + (-9223372036854775807L - 1);' "1:24: error: address offset exceeds supported range"
check_error global-initializer-pointer-offset-division-zero 'int a[2]; int *p = a + (1 / 0);' "1:31: error: division by zero in constant expression"

# Scalar global initializers use the converted value at the object's width.
check global-int-initializer 42 'int x = 42; int main(void) { return x; }'
check global-char-negative-initializer 1 'char x = -1; int main(void) { return x == -1; }'
check global-unsigned-char-initializer 1 'unsigned char x = 255; int main(void) { return x == 255; }'
check global-char-narrow-initializer 1 'char x = 511; int main(void) { return x == -1; }'
check global-unsigned-char-narrow-initializer 1 'unsigned char x = -1; int main(void) { return x == 255; }'
check global-short-negative-initializer 1 'short x = -32768; int main(void) { return x == -32768; }'
check global-unsigned-short-initializer 1 'unsigned short x = 65535; int main(void) { return x == 65535; }'
check global-short-narrow-initializer 1 'short x = 65535; int main(void) { return x == -1; }'
check global-unsigned-short-narrow-initializer 1 'unsigned short x = -1; int main(void) { return x == 65535; }'
check global-int-min-initializer 1 'int x = -2147483647 - 1; int main(void) { return x == -2147483647 - 1; }'
check global-unsigned-initializer 1 'unsigned x = 4294967295U; int main(void) { return x == 4294967295U; }'
check global-int-narrow-initializer 1 'int x = 4294967295U; int main(void) { return x == -1; }'
check global-unsigned-negative-initializer 1 'unsigned x = -1; int main(void) { return x == 4294967295U; }'
check global-long-initializer 1 'long x = 1099511627776L; int main(void) { return x == 1099511627776L; }'
check global-long-negative-initializer 1 'long x = -1099511627776L; int main(void) { return x == -1099511627776L; }'
check global-unsigned-long-initializer 1 'unsigned long x = 18446744073709551615UL; int main(void) { return x == 18446744073709551615UL; }'
check global-long-long-min-initializer 1 'long long x = -9223372036854775807LL - 1; int main(void) { return x == -9223372036854775807LL - 1; }'
check global-unsigned-long-long-initializer 1 'unsigned long long x = 18446744073709551615ULL; int main(void) { return x == 18446744073709551615ULL; }'
check global-enum-initializer 42 'enum E { ANSWER = 42 }; enum E x = ANSWER; int main(void) { return x; }'
check global-enum-negative-initializer 1 'enum E { NEG = -1 }; enum E x = NEG; int main(void) { return x == -1; }'
check global-typedef-initializer 42 'typedef unsigned long U; U x = 42; int main(void) { return x; }'
check global-constant-expression-initializer 42 'int x = 6 * 7; int main(void) { return x; }'
check global-sizeof-initializer 8 'unsigned long x = sizeof(long); int main(void) { return x; }'
check global-character-initializer 65 'int x = '\''A'\''; int main(void) { return x; }'
check global-conditional-initializer 42 'int x = 1 ? 42 : 1 / 0; int main(void) { return x; }'
check global-unevaluated-call-initializer 42 'int f(void); int x = 1 ? 42 : f(); int main(void) { return x; }'
check global-nonzero-tentative-definition 42 'int x; int x = 42; int x; int main(void) { return x; }'
check global-nonzero-followed-by-tentative 42 'int x = 42; int x; int main(void) { return x; }'
check global-initializer-after-reference 42 'int x; int f(void) { return x; } int x = 42; int main(void) { return f(); }'
check global-multiple-initializers 42 'int x = 20, y = 22; int main(void) { return x + y; }'
check global-initialized-object-writable 42 'int x = 20; int main(void) { x += 22; return x; }'
check global-initialized-object-address 42 'int x = 21; int main(void) { int *p = &x; *p *= 2; return x; }'
check global-initialized-neighbor-storage 1 'char a = 1, b = 2; short c = 3, d = 4; int main(void) { a = 7; c = 8; return a == 7 && b == 2 && c == 8 && d == 4; }'
check global-data-bss-text-rodata-sections 42 'int a = 10, z, b = 12; int f(void) { char *p = "A"; return p[0] - 45; } int c = 0; int main(void) { return a + z + b + f() + c; }'
check global-zero-initializer 0 'int x = 0; int main(void) { return x; }'
check global-zero-tentative-definition 0 'int x; int x = 0; int x; int main(void) { return x; }'
check global-zero-multiple-definitions 0 'int x = 0, y = 0; int main(void) { return x + y; }'
check global-zero-unevaluated-call 0 'int f(void); int x = 0 && f(); int main(void) { return x; }'
check global-zero-after-narrowing 0 'unsigned char x = 256; int main(void) { return x; }'
check_error global-initializer-redefinition 'int x = 1; int x = 2;' "1:16: error: redefinition of variable 'x'"
check_error global-initializer-zero-redefinition 'int x = 0; int x = 0;' "1:16: error: redefinition of variable 'x'"
check_error global-initializer-tentative-redefinition 'int x; int x = 0; int x = 1;' "1:23: error: redefinition of variable 'x'"
check_error global-initializer-comma-redefinition 'int x = 1, x = 2;' "1:12: error: redefinition of variable 'x'"
check_error global-initializer-conflicting-definition 'int x = 1; long x = 2;' "1:17: error: conflicting declaration of variable 'x'"
check_error global-initializer-variable-read 'int y; int x = y;' "1:16: error: global initializer is not a constant expression"
check_error global-initializer-initialized-variable-read 'int y = 1; int x = y;' "1:20: error: global initializer is not a constant expression"
check_error global-initializer-self-read 'int x = x;' "1:9: error: global initializer is not a constant expression"
check_error global-initializer-function-call 'int f(void); int x = f();' "1:22: error: global initializer is not a constant expression"
check_error global-initializer-assignment 'int y; int x = (y = 1);' "1:19: error: global initializer is not a constant expression"
check_error global-initializer-comma-expression 'int x = (1, 42);' "1:11: error: global initializer is not a constant expression"
check_error global-initializer-increment 'int y; int x = y++;' "1:17: error: global initializer is not a constant expression"
check_error global-initializer-evaluated-call 'int f(void); int x = 1 && f();' "1:24: error: global initializer is not a constant expression"
check_error global-initializer-incompatible-string 'int x = "A";' "1:5: error: incompatible initializer type"
check_error global-initializer-void-call 'void f(void); int x = f();' "1:23: error: void expression used as a value"
check_error global-initializer-array-unsupported 'int a[2] = {1,2};' "1:10: error: array initializers are not supported yet"
check_error global-initializer-struct-unsupported 'struct S { int x; }; struct S s = {1};' "1:33: error: struct initializers are not supported yet"
check_error global-initializer-division-by-zero 'int x = 1 / 0;' "1:14: error: division by zero in constant expression"
check_error global-initializer-signed-overflow 'int x = 2147483647 + 1;' "1:23: error: integer overflow in constant expression"
check_error global-initializer-invalid-shift 'int x = 1 << 32;' "1:16: error: invalid shift count in constant expression"
check_error global-initializer-missing-expression 'int x = ;' "1:9: error: expect expr"

# Global objects use zero-filled storage and RIP-relative addresses.
check global-char-zero-and-store 1 'char value; int main(void) { if (value != 0) return 0; value = -1; return value == -1; }'
check global-unsigned-char-zero-and-store 1 'unsigned char value; int main(void) { if (value != 0) return 0; value = 255; return value == 255; }'
check global-short-zero-and-store 1 'short value; int main(void) { if (value != 0) return 0; value = -1; return value == -1; }'
check global-unsigned-short-zero-and-store 1 'unsigned short value; int main(void) { if (value != 0) return 0; value = 65535; return value == 65535; }'
check global-int-zero-and-store 1 'int value; int main(void) { if (value != 0) return 0; value = -1; return value == -1; }'
check global-unsigned-zero-and-store 1 'unsigned value; int main(void) { if (value != 0) return 0; value = 4294967295U; return value == 4294967295U; }'
check global-long-zero-and-store 1 'long value; int main(void) { if (value != 0) return 0; value = 1099511627776L; return value == 1099511627776L; }'
check global-unsigned-long-zero-and-store 1 'unsigned long value; int main(void) { if (value != 0) return 0; value = 18446744073709551615UL; return value == 18446744073709551615UL; }'
check global-long-long-zero-and-store 1 'long long value; int main(void) { if (value != 0) return 0; value = -9223372036854775807LL; return value == -9223372036854775807LL; }'
check global-unsigned-long-long-zero-and-store 1 'unsigned long long value; int main(void) { if (value != 0) return 0; value = 18446744073709551615ULL; return value == 18446744073709551615ULL; }'
check global-assignment 42 'int x; int main(void) { x = 42; return x; }'
check global-pointer-zero 1 'int *p; int main(void) { return p == 0; }'
check global-pointer-store 42 'int x, *p; int main(void) { p = &x; *p = 42; return x; }'
check global-pointer-to-pointer 42 'int x, *p, **pp; int main(void) { pp = &p; p = &x; **pp = 42; return x; }'
check global-array-zero-and-store 42 'int a[3]; int main(void) { if (a[0] || a[1] || a[2]) return 0; a[2] = 42; return a[2]; }'
check global-char-array 42 'char a[5]; int main(void) { a[0] = 1; a[4] = 42; if (a[1] || a[2] || a[3]) return 0; return a[4]; }'
check global-short-array 1 'unsigned short a[3]; int main(void) { a[1] = 65535; return a[0] == 0 && a[1] == 65535 && a[2] == 0; }'
check global-long-array 1 'long a[3]; int main(void) { a[1] = 1099511627776L; return a[0] == 0 && a[1] == 1099511627776L && a[2] == 0; }'
check global-pointer-difference 3 'int a[3]; int main(void) { return (a + 3) - a; }'
check global-pointer-increment 42 'int a[3], *p; int main(void) { p = a; p++; *p = 42; return a[1]; }'
check global-struct-members 42 'struct S { char c; long value; }; struct S s; int main(void) { if (s.c || s.value) return 0; s.c = 7; s.value = 42; return s.value; }'
check global-struct-array-member 42 'struct S { int a[3]; }; struct S s; int main(void) { s.a[2] = 42; return s.a[2]; }'
check global-nested-struct 42 'struct I { short x; }; struct O { char c; struct I i; long n; }; struct O o; int main(void) { o.i.x = 42; o.n = 1099511627776L; if (o.n != 1099511627776L) return 0; return o.i.x; }'
check global-completed-struct 42 'struct S s; struct S { int value; struct S *next; }; int main(void) { s.value = 42; s.next = &s; return s.next->value; }'
check global-struct-storage-zero 1 'struct S { char c; long n; }; struct S s; int main(void) { void *raw = &s; unsigned char *bytes = raw; unsigned long i; for (i = 0; i < sizeof(s); i++) if (bytes[i] != 0) return 0; return 1; }'
check global-enum 42 'enum E { ANSWER = 42 }; enum E e; int main(void) { if (e != 0) return 0; e = ANSWER; return e; }'
check global-typedef 42 'typedef unsigned long Counter; Counter count; int main(void) { count = 42; return count; }'
check global-typedef-array 42 'typedef int A[3]; A a; int main(void) { a[2] = 42; return a[2]; }'
check global-repeated-declaration 42 'int x; int x; int main(void) { x = 42; return x; }'
check global-multiple-and-repeated 42 'int a, b, a, c; int main(void) { a = 10; b = 12; c = 20; return a + b + c; }'
check global-new-after-repeated 42 'int a; int a, b; int main(void) { a = 20; b = 22; return a + b; }'
check global-compatible-alias-redeclaration 42 'typedef int I; I x; int x; int main(void) { x = 42; return x; }'
check global-cross-function-store 42 'int x; int f(void) { x = 42; return 0; } int main(void) { f(); return x; }'
check global-recursive-state 42 'int count; int f(int n) { if (n == 0) return count; count++; return f(n - 1); } int main(void) { return f(42); }'
check global-parameter-shadow 42 'int x; int f(int x) { x = 7; return x; } int main(void) { x = 42; f(1); return x; }'
check global-block-shadow 42 'int x; int main(void) { x = 42; { int x = 7; if (x != 7) return 0; } return x; }'
check global-for-shadow 42 'int x; int main(void) { x = 42; for (int x = 0; x < 3; x++) {} return x; }'
check global-object-after-function 42 'int f(void) { return 20; } int x; int main(void) { x = 22; return f() + x; }'
check global-sections-after-string 98 'int f(void) { char *p = "abc"; return p[1]; } int x; int main(void) { x = f(); return x; }'
check global-pointer-to-string 65 'char *p; int main(void) { p = "A"; return p[0]; }'
check global-return-array-pointer 42 'int a[3]; int *f(void) { return a; } int main(void) { f()[1] = 42; return a[1]; }'
check global-return-struct-pointer 42 'struct S { int x; }; struct S s; struct S *f(void) { return &s; } int main(void) { f()->x = 42; return s.x; }'
check global-eighth-pointer-argument 42 'int x; int f(int a,int b,int c,int d,int e,int f,int g,int *p) { *p = a+b+c+d+e+f+g; return 0; } int main(void) { f(1,2,3,4,5,6,21,&x); return x; }'
check global-compound-assignment 42 'int x; int main(void) { x = 20; x += 22; return x; }'
check global-increment 42 'int x; int main(void) { x = 40; ++x; x++; return x; }'
check global-narrow-increment 1 'unsigned char c; int main(void) { c = 255; c++; return c == 0; }'
check global-byte-store-neighbor 1 'char a, b; int main(void) { b = 7; a = 1; return a == 1 && b == 7; }'
check global-short-store-neighbor 1 'short a, b; int main(void) { b = 7; a = 1; return a == 1 && b == 7; }'
check global-sizeof-array 12 'int a[3]; int main(void) { return sizeof(a); }'

# File-scope object declaration diagnostics.
check_error global-void 'void x;' "1:6: error: variable has void type"
check_error global-void-alias 'typedef void V; V x;' "1:19: error: variable has void type"
check_error global-conflicting-type 'int x; long x;' "1:13: error: conflicting declaration of variable 'x'"
check_error global-conflicting-array 'int a[2]; int a[3];' "1:15: error: conflicting declaration of variable 'a'"
check_error global-conflicting-pointer 'int *p; char *p;' "1:15: error: conflicting declaration of variable 'p'"
check_error global-function-conflict 'int f; int f(void);' "1:12: error: function conflicts with variable 'f'"
check_error global-variable-conflict 'int f(void); int f;' "1:18: error: variable conflicts with function 'f'"
check_error global-typedef-conflict 'typedef int T; int T;' "1:20: error: variable conflicts with typedef 'T'"
check_error global-typedef-name-conflict 'int T; typedef int T;' "1:20: error: typedef conflicts with variable 'T'"
check_error global-enumerator-conflict 'enum { X }; int X;' "1:17: error: variable conflicts with enumerator 'X'"
check_error global-enumerator-name-conflict 'int X; enum { X };' "1:15: error: enumerator conflicts with variable 'X'"
check_error global-incomplete 'struct S x;' "1:10: error: variable has incomplete type"
check_error global-repeated-incomplete 'struct S x; struct S x;' "1:10: error: variable has incomplete type"
check_error global-array-initializer-unsupported 'int a[3] = {0};' "1:10: error: array initializers are not supported yet"
check_error global-missing-name 'int;' "1:4: error: expect declaration name"
check_error global-missing-name-after-comma 'int a,;' "1:7: error: expect variable name"
check_error global-mixed-function-unsupported 'int a, f(void);' "1:9: error: function declarations in a declaration list are not supported yet"
check_error global-distinct-structs 'struct A { int x; }; struct B { int x; }; struct A a; struct B a;' "1:64: error: conflicting declaration of variable 'a'"
check_error global-use-before-declaration 'int f(void) { return x; } int x;' "1:22: error: undeclared identifier"
check_error global-nonconstant-array-bound 'int n; int a[n];' "1:15: error: not an integer constant expression"

# Declaration specifiers use one bitmask for built-in and named types.
check declspec-unsigned-shadows-typedef 42 'typedef int T; int main(void) { unsigned T = 42; return T; }'
check declspec-struct-alias-as-declarator 42 'typedef struct { int x; } S; int main(void) { S S; S.x = 42; return S.x; }'
check declspec-enum-alias-as-declarator 42 'typedef enum { A = 42 } E; int main(void) { E E = A; return E; }'
check_error declspec-unsigned-struct 'int main(void) { unsigned struct S x; }' "1:27: error: invalid combination of type specifiers"
check_error declspec-struct-unsigned 'int main(void) { struct S unsigned x; }' "1:27: error: invalid combination of type specifiers"
check_error declspec-unsigned-enum 'int main(void) { unsigned enum E x; }' "1:27: error: invalid combination of type specifiers"
check_error declspec-enum-unsigned 'enum E { A }; int main(void) { enum E unsigned x; }' "1:39: error: invalid combination of type specifiers"
check_error declspec-void-int 'int main(void) { void int x; }' "1:23: error: invalid combination of type specifiers"
check_error declspec-int-void 'int main(void) { int void x; }' "1:22: error: invalid combination of type specifiers"
check_error declspec-alias-unsigned 'typedef int T; int main(void) { T unsigned x; }' "1:35: error: invalid combination of type specifiers"
check_error declspec-duplicate-void 'typedef void void V;' "1:14: error: duplicate void type specifier"
check_error declspec-struct-enum 'struct S { int x; }; struct S enum E x;' "1:31: error: invalid combination of type specifiers"

# Ordinary identifier bindings preserve shadowing and file-scope functions.
check symbol-function-binding-below-parameter 42 'int f(int f); int main(void) { return f(42); } int f(int f) { return f; }'
check symbol-nested-kind-shadowing 42 'int X(void) { return 42; } int main(void) { { enum { X = 7 }; { typedef char X; { int X = 9; if (X != 9) return 0; } if (sizeof(X) != 1) return 0; } if (X != 7) return 0; } return X(); }'
check symbol-parameter-enum-restores-typedef 42 'typedef int T; int f(enum { T = 42 } x) { return T + x; } int main(void) { T x = 0; return f(x); }'
check symbol-recursive-binding-after-block 42 'int f(int n) { if (n == 0) return 42; { typedef char T; T x = 1; if (x != 1) return 0; } return f(n - 1); } int main(void) { return f(3); }'
check_error symbol-parameter-hides-function-call 'int f(int f) { return f(); }' "1:23: error: called object is not a function"
check_error symbol-file-conflict-hidden-by-parameter-enum 'typedef int f; int f(enum { f = 1 } x);' "1:20: error: function conflicts with typedef 'f'"
check_error symbol-file-enum-conflict-hidden-by-parameter 'enum { f }; int f(int f);' "1:17: error: function conflicts with enumerator 'f'"

# Typedef declarations and ordinary identifier scope.
check typedef-tag-only 42 'typedef struct S; typedef struct S S; struct S { int x; }; int main(void) { S s; s.x = 42; return s.x; }'
check typedef-enum-only 42 'typedef enum { A = 42 }; int main(void) { return A; }'
check typedef-integer 42 'typedef int I; int main(void) { I x = 42; return x; }'
check typedef-local 42 'int main(void) { typedef int I; I x = 42; return x; }'
check typedef-unsigned 1 'typedef unsigned U; int main(void) { U x = 4294967295U; return x > 0; }'
check typedef-char 255 'typedef char C; int main(void) { C x = 255; return x; }'
check typedef-unsigned-char 1 'typedef unsigned char C; int main(void) { C x = 255; return x == 255; }'
check typedef-short 255 'typedef short S; int main(void) { S x = 65535; return x; }'
check typedef-unsigned-short 1 'typedef unsigned short S; int main(void) { S x = 65535; return x == 65535; }'
check typedef-long 8 'typedef long L; int main(void) { return sizeof(L); }'
check typedef-unsigned-long-long 1 'typedef unsigned long long U; int main(void) { U x = 18446744073709551615ULL; return x > 0; }'
check typedef-chain 42 'typedef int I; typedef I J; int main(void) { J x = 42; return x; }'
check typedef-pointer 42 'typedef int *P; int main(void) { int x = 42; P p = &x; return *p; }'
check typedef-pointer-declarator 42 'typedef int I; int main(void) { I x = 42; I *p = &x; return *p; }'
check typedef-array 42 'typedef int A[3]; int main(void) { A a; a[2] = 42; return a[2]; }'
check typedef-array-sizeof 12 'typedef int A[3]; int main(void) { return sizeof(A); }'
check typedef-array-parameter 42 'typedef int A[3]; int f(A a) { return a[2]; } int main(void) { A a; a[2] = 42; return f(a); }'
check typedef-anonymous-struct 42 'typedef struct { int x; } S; int main(void) { S s; s.x = 42; return s.x; }'
check typedef-forward-struct 42 'typedef struct Node Node; struct Node { int value; Node *next; }; int main(void) { Node n; n.value = 42; n.next = &n; return n.next->value; }'
check typedef-enum 42 'typedef enum { ANSWER = 42 } E; int main(void) { E e = ANSWER; return e; }'
check typedef-struct-member 42 'typedef int I; struct S { I x; }; int main(void) { struct S s; s.x = 42; return s.x; }'
check typedef-function-signature 42 'typedef int I; I f(I x); I f(I x) { return x; } int main(void) { return f(42); }'
check typedef-void 42 'typedef void V; V f(V) { return; } int main(V) { f(); return 42; }'
check typedef-repeat 42 'typedef int I; typedef I I; int main(void) { I x = 42; return x; }'
check typedef-repeat-pointer 8 'typedef int *P; typedef int *P; int main(void) { return sizeof(P); }'
check typedef-repeat-array 12 'typedef int A[3]; typedef int A[3]; int main(void) { return sizeof(A); }'
check typedef-repeat-enum 4 'typedef enum E { A } E; typedef enum E E; int main(void) { return sizeof(E); }'
check typedef-hides-variable 42 'int main(void) { int T = 42; { typedef char T; T x = 1; if (sizeof(x) != 1) return 0; } return T; }'
check typedef-hides-enumerator 42 'enum { T = 42 }; int main(void) { { typedef char T; T x; if (sizeof(x) != 1) return 0; } return T; }'
check typedef-hides-function 42 'int T(void) { return 42; } int main(void) { { typedef char T; T x; if (sizeof(x) != 1) return 0; } return T(); }'
check typedef-variable-hides-alias 42 'typedef int T; int main(void) { { int T = 42; return T; } }'
check typedef-enumerator-hides-alias 42 'typedef int T; int main(void) { enum { T = 42 }; return T; }'
check typedef-parameter-hides-alias 42 'typedef int T; int f(int T) { return T; } int main(void) { return f(42); }'
check typedef-prototype-restores-alias 42 'typedef int T; int f(int T); int main(void) { T x = 42; return x; }'
check typedef-definition-restores-alias 42 'typedef int T; int f(int T) { return T; } int main(void) { T x = 42; return f(x); }'
check typedef-block-restores-alias 4 'typedef int T; int main(void) { { typedef char T; if (sizeof(T) != 1) return 0; } return sizeof(T); }'
check typedef-for-type 42 'typedef int T; int main(void) { int sum = 0; for (T i = 0; i < 7; i++) sum += 6; return sum; }'
check typedef-for-restores-alias 4 'typedef int T; int main(void) { for (int T = 0; T < 1; T++) {} return sizeof(T); }'
check typedef-for-body-restores-alias 4 'typedef int T; int main(void) { for (int i = 0; i < 1; i++) { typedef char T; if (sizeof(T) != 1) return 0; } return sizeof(T); }'
check typedef-label-namespace 42 'typedef int T; int main(void) { goto T; T: return 42; }'
check typedef-tag-member-namespace 42 'typedef int T; struct T { int T; }; int main(void) { struct T t; t.T = 42; return t.T; }'
check typedef-multiple-declarators 42 'typedef int I, *P, A[2]; int main(void) { A a; P p = a; I x = 42; p[1] = x; return a[1]; }'
check typedef-earlier-declarator-visible 42 'typedef int I, A[sizeof(I)]; int main(void) { A a; a[3] = 42; return a[3]; }'
check typedef-storage-after-type 42 'int typedef I; int main(void) { I x = 42; return x; }'
check typedef-storage-between-types 42 'unsigned typedef long U; int main(void) { U x = 42; return x; }'
check typedef-storage-after-alias 42 'typedef int I; I typedef J; int main(void) { J x = 42; return x; }'
check typedef-storage-after-struct 42 'struct S { int x; } typedef S; int main(void) { S s; s.x = 42; return s.x; }'
check typedef-sizeof-hidden-alias 42 'typedef int T; int main(void) { int T = 42; return sizeof(T) + T - 4; }'
check typedef-alias-as-variable-name 42 'typedef int T; int main(void) { T T = 42; return T; }'
check typedef-alias-as-parameter-name 42 'typedef int T; int f(T T) { return T; } int main(void) { return f(42); }'
check typedef-label-preserves-alias 42 'typedef int T; int main(void) { T: ; T x = 42; return x; }'

check_error typedef-conflicting-type 'typedef int T; typedef long T;' "1:29: error: conflicting typedef for 'T'"
check_error typedef-conflicting-array 'typedef int A[2]; typedef int A[3];' "1:31: error: conflicting typedef for 'A'"
check_error typedef-enum-integer-distinct 'typedef enum E { A } T; typedef int T;' "1:37: error: conflicting typedef for 'T'"
check_error typedef-enum-pointer-distinct 'typedef enum E { A } *P; typedef int *P;' "1:39: error: conflicting typedef for 'P'"
check_error typedef-variable-conflict 'int main(void) { typedef int T; int T; }' "1:37: error: variable conflicts with typedef 'T'"
check_error typedef-local-conflict 'int main(void) { int T; typedef int T; }' "1:37: error: typedef conflicts with variable 'T'"
check_error typedef-enumerator-conflict 'enum { T }; typedef int T;' "1:25: error: typedef conflicts with enumerator 'T'"
check_error typedef-enum-name-conflict 'typedef int T; enum { T };' "1:23: error: enumerator conflicts with typedef 'T'"
check_error typedef-function-conflict 'int f(void); typedef int f;' "1:26: error: typedef conflicts with function 'f'"
check_error typedef-function-name-conflict 'typedef int f; int f(void);' "1:20: error: function conflicts with typedef 'f'"
check_error typedef-function-conflict-hidden-by-parameter 'typedef int f; int f(int f) { return f; }' "1:20: error: function conflicts with typedef 'f'"
check_error typedef-parameter-conflict 'int f(int x) { typedef int x; return x; }' "1:28: error: typedef conflicts with variable 'x'"
check_error typedef-initializer 'typedef int T = 1;' "1:15: error: typedef cannot have an initializer"
check_error typedef-missing-name 'typedef int;' "1:12: error: expect typedef name"
check_error typedef-missing-pointer-alias 'typedef int *;' "1:14: error: expect typedef name"
check_error typedef-duplicate-storage 'typedef typedef int T;' "1:9: error: duplicate typedef specifier"
check_error typedef-storage-in-sizeof 'int main(void) { return sizeof(typedef int); }' "1:32: error: typedef is not allowed here"
check_error typedef-storage-in-member 'struct S { typedef int T; };' "1:12: error: typedef is not allowed here"
check_error typedef-storage-in-parameter 'int f(typedef int T);' "1:7: error: typedef is not allowed here"
check_error typedef-name-as-expression 'typedef int T; int main(void) { return T; }' "1:40: error: typedef name is not an expression"
check_error typedef-name-as-call 'typedef int T; int main(void) { return T(); }' "1:40: error: typedef name is not an expression"
check_error typedef-storage-in-for 'int main(void) { for (typedef int T; ; ) {} }' "1:23: error: typedef is not allowed in a for initializer"
check_error typedef-declaration-as-body 'typedef int T; int main(void) { if (1) T x; }' "1:40: error: expect statement"
check_error typedef-typedef-as-body 'int main(void) { if (1) typedef int T; }' "1:25: error: expect statement"
check_error typedef-function-scope-restored 'int f(void) { typedef int T; return 0; } int main(void) { T x; return 0; }' "1:59: error: undeclared identifier"
check_error typedef-hidden-parameter-type 'typedef int T; int f(int T, T x);' "1:29: error: expect type specifier"
check_error typedef-function-type-unsupported 'typedef int F(int);' "1:14: error: function typedefs are not supported yet"

check main-empty-body 0 'int main() {}'
check return-integer-literal 42 'int main() { return 42; }'
check addition-adjacent-tokens 3 'int main() { return 1+2; }'
check addition-extra-whitespace 4 'int main() { return 1 +        1 +1+1; }'
check addition-parenthesized 3 'int main() { return (1+2); }'
check multiplication-literals 2 'int main() { return 1 * 2; }'
check multiplication-parenthesized-sum 9 'int main() { return 3 * (1+2); }'
check division-parenthesized-sum 1 'int main() { return (1+2) / 3; }'
check unary-negation-literal 255 'int main() { return -1; }'
check logical-not-nonzero-literal 0 'int main() { return !1; }'
check bitwise-not-literal 245 'int main() { return ~10; }'
check logical-not-repeated 1 'int main() { return !!10; }'
check parentheses-nested-literal 42 'int main() { return (((42))); }'
check negation-parenthesized-negative 42 'int main() { return -(-6) * 7; }'
check arithmetic-negative-factor 42 'int main() { return 2 * -3 + 48; }'
check expression-multiline-whitespace 42 $'int main() { return (\n6 * 7\n)\n;\n }'
check local-initializer-read 42 'int main() { int a = 42; return a; }'
check local-assignment-read 42 'int main() { int a; a = 42; return a; }'
check locals-multiply 42 'int main() { int a; int b; a = 6; b = 7; return a * b; }'
check local-reassignment-arithmetic 49 'int main() { int a = 6; a = a + 1; return a * 7; }'
check local-shadow-inner-return 42 'int main() { int a = 1; { int a = 42; return a; } }'
check local-shadow-restores-outer 42 'int main() { int a = 42; { int a = 41; } return a; }'
check main-fallthrough-with-locals 0 'int main() { int a = 1; int b = 2; }'
check nested-block-updates-outer 42 'int main() { int a = 40; { int b = 2; a = a + b; } return a; }'
check local-shadow-inner-assignment 12 'int main() { int a = 4; { int a = 9; a = a + 3; } return a + 8; }'
check arithmetic-parenthesized-local-operands 42 'int main() { int a = 21; int b = 3; return (a + b) + (a - b); }'
check assignment-nested-in-product 42 'int main() { int a; int b = 4; a = (b = 6) * 7; return a; }'
check subtraction-negative-product 42 'int main() { int a = 12; int b  = -5; return a - b * 6; }'
check local-repeated-arithmetic-assignment 42 'int main() { int a; a = 4 + 2 * 7; a = a * 2 + 6; return a; }'
check assignment-parenthesized-lvalue 42 'int main() { int a; (a ) = 42; return a; }'
check empty-and-value-expression-statements 42 'int main() { int a = 42; ; a; return a; }'
check local-name-reused-after-block 42 'int main() { { int x = 3; } int x = 42; return x; }'
check locals-nine-variable-sum 42 'int main() { int a=0; int b=1; int c=2; int d=3; int e=4; int f=5; int g=6; int h=7; int i=14; return a+b+c+d+e+f+g+h+i; }'
check main-fallthrough-after-assignment 0 'int main() { int a = 42; a = 24; }'
check return-skips-later-assignment 42 'int main() { int a = 42; return a; a = 7; }'
check shadowing-begins-at-declaration 2 'int main() { int a = 1; { a = 2; int a = 3; a = 4; } return a; }'
check local-shadow-sibling-blocks 5 'int main() { int a = 5; { int a = 4; } { int a = 7; a = 9; } return a; }'
check identifier-distinct-prefixes 42 'int main() { int a = 10; int aa = 32; return a + aa; }'
check identifier-underscore-and-uppercase 42 'int main() { int _a = 20; int A1 = 22; return _a + A1; }'
check long-keyword-prefix-identifiers 42 'int main() { int longer = 20; int long_ = 21; int long1 = 1; return longer + long_ + long1; }'
check short-keyword-prefix-identifiers 42 'int main() { int shorter = 20; int short_ = 21; int short1 = 1; return shorter + short_ + short1; }'
check assignment-in-local-initializer 42 'int main() { int a = 0; int b = (a = 40) + 2; return b; }'
check return-assignment-expression 42 'int main() { int a; return a = 6 * 7; }'
check identifier-containing-keyword 42 'int main() { int while_count = 40; int return_value = 2; int _Boolish = 0; return while_count + return_value + _Boolish; }'
check integer-max-subtraction 42 'int main() { return 2147483647 - 2147483605; }'
check integer-max-division 1 'int main() { return 2147483647 / 2147483647; }'
check integer-max-negation-cancellation 1 'int main() { return - 2147483647 + 2147483647 + 1; }'
check octal-many-leading-zeros 7 'int main() { return 000000000000000000000000000000007; }'
check octal-zero 0 'int main() { return 0; }'
check octal-zeros 0 'int main() { return 000; }'
check octal-seven 7 'int main() { return 07; }'
check octal-ten 8 'int main() { return 010; }'
check octal-fifty-two 42 'int main() { return 052; }'
# Integer suffix spelling and token boundaries.
for suffix in U u L l UL Ul uL ul LU Lu lU lu LL ll ULL Ull uLL ull LLU LLu llU llu; do
    check "integer-suffix-decimal-$suffix" 42 "int main(void) { return 42$suffix; }"
    check "integer-suffix-octal-$suffix" 42 "int main(void) { return 052$suffix; }"
done
check integer-suffix-before-operator 42 'int main(void) { return 1U+051L; }'
check integer-suffix-zero 0 'int main(void) { return 0uL; }'
check_error integer-suffix-duplicate-unsigned 'int main(void) { return 42UU; }' '1:25: error: invalid integer suffix'
check_error integer-suffix-duplicate-unsigned-case 'int main(void) { return 42Uu; }' '1:25: error: invalid integer suffix'
check_error integer-suffix-duplicate-unsigned-after-long 'int main(void) { return 42ULU; }' '1:25: error: invalid integer suffix'
check_error integer-suffix-long-long-mixed-case 'int main(void) { return 42lL; }' '1:25: error: invalid integer suffix'
for suffix in Ll ULl lLU LLL lll lUl LuL ULLU LLUU LL2 ll_name; do
    check_error "integer-suffix-invalid-$suffix" "int main(void) { return 42$suffix; }" '1:25: error: invalid integer suffix'
done
check_error integer-suffix-trailing-letter 'int main(void) { return 42ULx; }' '1:25: error: invalid integer suffix'
check_error integer-suffix-trailing-digit 'int main(void) { return 42U2; }' '1:25: error: invalid integer suffix'
check_error integer-suffix-trailing-underscore 'int main(void) { return 42L_name; }' '1:25: error: invalid integer suffix'
check_error integer-suffix-invalid-octal 'int main(void) { return 08U; }' '1:25: error: invalid digit in octal integer literal'

check prefix-increment-result 42 'int main() { int a = 41; return ++a; }'
check postfix-increment-original-value 41 'int main() { int a = 41; return a++; }'
check prefix-decrement-result 42 'int main() { int a = 43; return --a; }'
check postfix-decrement-original-value 42 'int main() { int a = 42; return a--; }'
check postfix-increment-updates-local 42 'int main() { int a = 41; a++; return a; }'
check prefix-decrement-updates-local 42 'int main() { int a = 43; --a; return a; }'
check prefix-and-postfix-increment-sequence 42 'int main() { int a = 40; ++a; a++; return a; }'
check equality-equal-literals 1 'int main() { return 1 == 1; }'
check equality-unequal-literals 0 'int main() { return 1 == 2; }'
check inequality-unequal-literals 1 'int main() { return 1 != 2; }'
check inequality-equal-literals 0 'int main() { return 1 != 1; }'
check less-than-true 1 'int main() { return 1 < 2; }'
check less-than-false 0 'int main() { return 2 < 1; }'
check less-equal-equal-operands 1 'int main() { return 1 <= 1; }'
check less-equal-false 0 'int main() { return 2 <= 1; }'
check greater-than-true 1 'int main() { return 2 > 1; }'
check greater-than-false 0 'int main() { return 1 > 2; }'
check greater-equal-equal-operands 1 'int main() { return 2 >= 2; }'
check greater-equal-false 0 'int main() { return 1 >= 2; }'
check relational-before-equality 1 'int main() { return 1 < 2 == 1; }'
check relational-before-inequality 0 'int main() { return 1 < 2 != 1; }'
check addition-before-equality 1 'int main() { int a = 41; return a + 1 == 42; }'
check addition-before-relational 1 'int main() { return 1 + 1 < 3; }'
check remainder-literals 1 'int main() { return 7 % 3; }'
check remainder-larger-dividend 2 'int main() { return 10 % 4; }'
check remainder-negative-dividend 255 'int main() { return -7 % 3; }'
check remainder-exact-division 0 'int main() { return 6 % 2; }'
check multiplication-before-remainder 2 'int main() { return 4 * 3 % 5; }'
check compound-add-local 42 'int main() { int a = 40; a += 2; return a; }'
check compound-subtract-local 42 'int main() { int a = 44; a -= 2; return a; }'
check compound-multiply-local 42 'int main() { int a = 14; a *= 3; return a; }'
check compound-divide-local 42 'int main() { int a = 84; a /= 2; return a; }'
check compound-remainder-local 42 'int main() { int a = 85; a %= 43; return a; }'
check compound-add-expression-result 42 'int main() { int a = 40; return a += 2; }'
check compound-multiply-local-operand 42 'int main() { int a = 6; int b = 7; a *= b; return a; }'
check compound-remainder-zero-result 0 'int main() { int a = 42; a %= 7; return a; }'
check left-shift-literals 8 'int main() { return 1 << 3; }'
check right-shift-literals 2 'int main() { return 8 >> 2; }'
check addition-before-shift 32 'int main() { return 1 << 2 + 3; }'
check right-shift-three-bits 2 'int main() { return 16 >> 3; }'
check shift-left-associativity 8 'int main() { return 8 >> 1 << 1; }'
check signed-right-shift-negative 252 'int main() { return -8 >> 1; }'
check left-shift-zero-count 1 'int main() { return 1 << 0; }'
check right-shift-non-power-of-two 21 'int main() { return 42 >> 1; }'
check left-right-shift-sequence 42 'int main() { int a = 42; return a << 2 >> 2; }'
check compound-left-shift-local 40 'int main() { int a = 5; a <<= 3; return a; }'
check compound-right-shift-local 10 'int main() { int a = 40; a >>= 2; return a; }'
check compound-left-shift-expression-result 16 'int main() { int a = 1; return a <<= 4; }'
check if-true-return 42 'int main() { if (1) return 42; return 24; }'
check if-false-falls-through 24 'int main() { if (0) return 42; return 24; }'
check if-else-true-return 42 'int main() { if (1) return 42; else return 24; }'
check if-else-false-return 24 'int main() { if (0) return 42; else return 24; }'
check if-else-compound-true 42 'int main() { if (1) { return 42; } else { return 24; } }'
check if-else-compound-false 24 'int main() { if (0) { return 42; } else { return 24; } }'
check if-local-equality-condition 42 'int main() { int a = 1; if (a == 1) return 42; return 0; }'
check if-local-zero-condition 42 'int main() { int a = 0; if (a) return 24; else return 42; }'
check if-else-if-chain 42 'int main() { if (2 < 1) return 24; else if (1 < 2) return 42; else return 0; }'
check if-true-assignment 42 'int main() { int a = 1; if (a == 1) a = 42; return a; }'
check if-false-skips-assignment 1 'int main() { int a = 1; if (a == 0) a = 42; return a; }'
check dangling-else-inner-false 42 'int main() { int a = 1; int b = 0; if (a) if (b) return 24; else return 42; return 0; }'
check dangling-else-outer-false 0 'int main() { int a = 0; int b = 0; if (a) if (b) return 24; else return 42; return 0; }'
check if-empty-then-else-return 42 'int main() { if (0) ; else return 42; return 0; }'
check if-postincrement-true-condition 42 'int main() { int a = 1; if (a++) return 42; return 0; }'
check if-postincrement-false-side-effect 1 'int main() { int a = 0; if (a++) return 42; return a; }'
check if-block-local-return 42 'int main() { if (1) { int a = 42; return a; } return 0; }'
check if-empty-else-falls-through 42 'int main() { if (0) return 24; else ; return 42; }'
check while-countdown-sum 6 'int main() { int i = 3; int sum = 0; while (i) { sum = sum + 2; i = i - 1; } return sum; }'
check while-zero-skips-body 0 'int main() { int i = 0; int sum = 0; while (i) sum = sum + 1; return sum; }'
check while-counts-to-limit 3 'int main() { int i = 0; while (i < 3) i = i + 1; return i; }'
check while-local-countdown 0 'int main() { int i = 3; while (i) i = i - 1; return i; }'
check while-early-return 42 'int main() { int i = 5; while (i) { if (i == 2) return 42; i = i - 1; } return 0; }'
check while-empty-body-postincrement 4 'int main() { int i = 0; while (i++ < 3) ; return i; }'
check while-zero-empty-body 0 'int main() { while (0) ; return 0; }'
check while-nested-loop-count 9 'int main() { int i = 3; int j; int n = 0; while (i) { j = 3; while (j) { n = n + 1; j = j - 1; } i = i - 1; } return n; }'
check for-empty-body-count 3 'int main() { int i; for (i = 0; i < 3; i = i + 1) ; return i; }'
check for-accumulates-sum 6 'int main() { int i; int sum = 0; for (i = 0; i < 4; i = i + 1) sum = sum + i; return sum; }'
check for-early-return 42 'int main() { int i; for (i = 0; i < 10; i = i + 1) if (i == 5) return 42; return 0; }'
check for-declaration-accumulates-sum 6 'int main() { int sum = 0; for (int i = 0; i < 4; i = i + 1) sum = sum + i; return sum; }'
check for-declaration-scope-exit 42 'int main() { for (int i = 0; i < 3; i = i + 1) ; int i = 42; return i; }'
check for-omitted-clauses 42 'int main() { int i = 0; for (;;) { i = i + 1; if (i == 42) return i; } }'
check for-omitted-initializer 1 'int main() { int i = 0; for (; i < 3; i = i + 1) ; return i == 3; }'
check for-nested-loop-count 9 'int main() { int i; int j; int n = 0; for (i = 0; i < 3; i = i + 1) for (j = 0; j < 3; j = j + 1) n = n + 1; return n; }'
check logical-and-both-true 1 'int main() { return 1 && 1; }'
check logical-and-right-false 0 'int main() { return 1 && 0; }'
check logical-and-left-false 0 'int main() { return 0 && 1; }'
check logical-or-left-true 1 'int main() { return 1 || 0; }'
check logical-or-right-true 1 'int main() { return 0 || 1; }'
check logical-or-both-false 0 'int main() { return 0 || 0; }'
check logical-and-short-circuits-assignment 42 'int main() { int a = 42; 0 && (a = 1); return a; }'
check logical-or-short-circuits-assignment 42 'int main() { int a = 42; 1 || (a = 1); return a; }'
check logical-and-evaluates-right-assignment 1 'int main() { int a = 0; 1 && (a = 1); return a; }'
check logical-or-evaluates-right-assignment 1 'int main() { int a = 0; 0 || (a = 1); return a; }'
check logical-and-normalizes-nonzero-literals 1 'int main() { return 2 && 3; }'
check logical-and-normalizes-local 1 'int main() { int a = 2; return a && a; }'
check logical-and-before-or 1 'int main() { return 1 || 0 && 0; }'
check logical-parentheses-override-precedence 0 'int main() { return (1 || 0) && 0; }'
check if-logical-and-equality-conditions 42 'int main() { int a = 1; int b = 2; if (a == 1 && b == 2) return 42; return 0; }'
check while-mixed-logical-condition 3 'int main() { int i = 0; while (i < 3 && i != 0 || i == 0) i = i + 1; return i; }'
check bitwise-and-shared-bit 1 'int main() { return 1 & 1; }'
check bitwise-and-disjoint-bits 0 'int main() { return 1 & 2; }'
check bitwise-or-disjoint-bits 3 'int main() { return 1 | 2; }'
check bitwise-or-zero-operands 0 'int main() { return 0 | 0; }'
check bitwise-xor-disjoint-bits 3 'int main() { return 1 ^ 2; }'
check bitwise-xor-identical-operands 0 'int main() { return 5 ^ 5; }'
check bitwise-and-mask 12 'int main() { return 12 & 15; }'
check bitwise-or-merge 15 'int main() { return 12 | 3; }'
check bitwise-and-before-or 3 'int main() { return 1 | 2 & 2; }'
check bitwise-xor-before-or 7 'int main() { return 2 | 4 ^ 3; }'
check bitwise-and-before-xor 4 'int main() { return 2 & 4 ^ 4; }'
check equality-before-bitwise-and 1 'int main() { return 1 & 2 == 2; }'
check bitwise-operators-before-logical-and 1 'int main() { return 5 & 3 && 5 | 3; }'
check compound-bitwise-or-local 6 'int main() { int a = 4; a |= 2; return a; }'
check compound-bitwise-and-local 8 'int main() { int a = 12; a &= 10; return a; }'
check compound-bitwise-xor-local 7 'int main() { int a = 3; a ^= 4; return a; }'
check compound-bitwise-or-expression-result 5 'int main() { int a = 1; return a |= 4; }'
check compound-xor-swap 24 'int main() { int a = 42; int b = 24; a ^= b; b ^= a; a ^= b; return a; }'
check do-while-zero-runs-once 1 'int main() { int i = 0; do { i = i + 1; } while (0); return i; }'
check do-while-counts-to-limit 3 'int main() { int i = 0; do { i = i + 1; } while (i < 3); return i; }'
check do-while-early-return 42 'int main() { int i = 0; do { i = i + 1; if (i == 42) return i; } while (1); }'
check do-while-countdown-sum 6 'int main() { int i = 3; int sum = 0; do { sum = sum + i; i = i - 1; } while (i); return sum; }'
check do-while-postincrement-condition 4 'int main() { int i = 0; do { i = i + 1; } while (i++ < 3); return i; }'
check do-while-single-statement-body 1 'int main() { int i = 0; do i = i + 1; while (0); return i; }'
check do-while-nested-loop-count 9 'int main() { int i = 0; int j; int n = 0; do { j = 0; do { n = n + 1; j = j + 1; } while (j < 3); i = i + 1; } while (i < 3); return n; }'
check comment-line-before-return 42 $'int main() { // comment\n return 42; }'
check comment-block-before-return 42 'int main() { /* comment */ return 42; }'
check comment-block-multiline 42 $'int main() { /* multi\nline\ncomment */ return 42; }'
check comment-between-return-and-operand 42 'int main() { return /* inline */ 42; }'
check comments-between-arithmetic-tokens 7 'int main() { /* a */ return /* b */ 3 /* c */ + /* d */ 4; }'
check comment-line-at-end-of-file 0 $'int main() { return 0; } // trailing comment'
check while-break-at-limit 42 'int main() { int i = 0; while (1) { i = i + 1; if (i == 42) break; } return i; }'
check while-immediate-break 0 'int main() { while (1) break; return 0; }'
check while-continue-skips-odd-values 5 'int main() { int i = 0; int n = 0; while (i < 10) { i = i + 1; if (i % 2) continue; n = n + 1; } return n; }'
check for-continue-skips-odd-values 5 'int main() { int i; int n = 0; for (i = 0; i < 10; i = i + 1) { if (i % 2) continue; n = n + 1; } return n; }'
check do-while-continue-skips-odd-values 5 'int main() { int i = 0; int n = 0; do { i = i + 1; if (i % 2) continue; n = n + 1; } while (i < 10); return n; }'
check do-while-break-before-condition 3 'int main() { int i = 0; do { i = i + 1; if (i == 3) break; } while (1); return i; }'
check nested-for-break-inner-loop 9 'int main() { int i; int j; int n = 0; for (i = 0; i < 3; i = i + 1) for (j = 0; j < 10; j = j + 1) { if (j == 3) break; n = n + 1; } return n; }'
check nested-for-continue-inner-loop 6 'int main() { int i; int j; int n = 0; for (i = 0; i < 3; i = i + 1) for (j = 0; j < 3; j = j + 1) { if (j == 1) continue; n = n + 1; } return n; }'
check goto-forward-label 42 'int main() { goto end; return 24; end: return 42; }'
check goto-backward-loop-sum 6 'int main() { int i = 0; int sum = 0; loop: sum = sum + i; i = i + 1; if (i <= 3) goto loop; return sum; }'
check goto-empty-labeled-statement 42 'int main() { int i = 0; L: ; i = i + 1; if (i < 2) goto L; return 42; }'
check goto-exits-while-loop 42 'int main() { int i = 0; while (i < 2) { i = i + 1; if (i == 2) goto done; } return 0; done: return 42; }'
check goto-from-if-branch 42 'int main() { if (1) goto L; return 24; L: return 42; }'
check switch-selects-matching-case 42 'int main() { int x = 2; switch (x) { case 1: return 24; case 2: return 42; case 3: return 0; } return 0; }'
check switch-selects-default 42 'int main() { int x = 9; switch (x) { case 1: return 24; default: return 42; } }'
check switch-no-match-falls-through 7 'int main() { int x = 9; switch (x) { case 1: x = 1; case 2: x = 2; } return 7; }'
check switch-break-after-assignment 42 'int main() { int x = 2; switch (x) { case 1: x = 24; break; case 2: x = 42; break; default: x = 0; } return x; }'
check switch-case-fallthrough 42 'int main() { int x = 1; int n = 0; switch (x) { case 1: n = n + 40; case 2: n = n + 2; } return n; }'
check switch-case-constant-arithmetic 42 'int main() { int x = 5; switch (x) { case 2 + 3: return 42; default: return 0; } }'
check switch-negative-case-value 42 'int main() { int x = -1; switch (x) { case -1: return 42; default: return 0; } }'
check switch-break-preserves-enclosing-loop 42 'int main() { int i; for (i = 0; i < 3; i = i + 1) { switch (i) { case 0: break; case 1: break; case 2: return 42; } } return 0; }'
check switch-nested-dispatch 42 'int main() { int a = 1; int b = 2; switch (a) { case 1: switch (b) { case 2: return 42; } } return 0; }'
check switch-case-in-nested-block 42 'int main() { int x = 2; switch (x) { { case 2: return 42; } } return 0; }'
check function-definition-before-main 42 'int foo() { return 24; } int main() { return 42; }'
check function-definition-after-main 42 'int main() { return 42; } int foo() { return 24; }'
check labels-independent-between-functions 42 'int foo() { L: ; return 24; } int main() { L: ; return 42; }'
check function-control-flow-state-reset 42 'int foo() { int x = 0; while (x < 3) x = x + 1; switch (x) { case 3: return 42; } return 0; } int main() { return 42; }'
check call-no-argument-function 42 'int foo() { return 42; } int main() { return foo(); }'
check call-result-in-addition 42 'int foo() { return 40; } int main() { return foo() + 2; }'
check call-as-expression-statement 42 'int foo() { return 42; } int main() { foo(); return 42; }'
check call-twice-in-expression 42 'int foo() { return 21; } int main() { return foo() + foo(); }'
check call-through-another-function 42 'int foo() { return 42; } int bar() { return foo(); } int main() { return bar(); }'
check call-three-times-in-expression 3 'int one() { return 1; } int main() { return one() + one() + one(); }'
check call-in-nested-arithmetic 127 'int foo() { return 40; } int main() { return 1 + (2 + foo()) * 3; }'
check call-two-integer-arguments 42 'int add(int a, int b) { return a + b; } int main() { return add(40, 2); }'
check call-one-integer-argument 42 'int add1(int a) { return a + 1; } int main() { return add1(41); }'
check recursion-factorial 120 'int fact(int n) { if (n == 0) return 1; return n * fact(n - 1); } int main() { return fact(5); }'
check recursion-fibonacci 55 'int fib(int n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } int main() { return fib(10); }'
check call-six-integer-arguments 21 'int sum6(int a, int b, int c, int d, int e, int f) { return a + b + c + d + e + f; } int main() { return sum6(1, 2, 3, 4, 5, 6); }'
check call-local-as-second-argument 42 'int pick(int a, int b) { return b; } int main() { int x = 42; return pick(0, x); }'
check function-prototype-before-definition 42 'int foo(int a); int foo(int a) { return a + 41; } int main() { return foo(1); }'
check function-prototype-after-definition 42 'int foo(int a) { return a + 41; } int foo(int a); int main() { return foo(1); }'
check function-repeated-prototypes 42 'int foo(int a); int foo(int a); int main() { return foo(1); } int foo(int a) { return a + 41; }'
check recursion-mutual-even-odd 42 'int is_even(int n); int is_odd(int n) { if (n == 0) return 0; return is_even(n - 1); } int is_even(int n) { if (n == 0) return 1; return is_odd(n - 1); } int main() { if (is_even(10)) return 42; return 0; }'
check conditional-true-literal 42 'int main() { return 1 ? 42 : 24; }'
check conditional-false-literal 24 'int main() { return 0 ? 42 : 24; }'
check conditional-nonzero-condition 42 'int main() { return 5 ? 42 : 24; }'
check conditional-skips-false-assignment 42 'int main() { int a = 42; 1 ? a : (a = 0); return a; }'
check conditional-skips-true-assignment 42 'int main() { int a = 42; 0 ? (a = 0) : 1; return a; }'
check conditional-right-associativity 42 'int main() { return 0 ? 24 : 1 ? 42 : 0; }'
check conditional-nested-true-arm 42 'int main() { return 1 ? 0 ? 24 : 42 : 0; }'
check conditional-parenthesized-in-product 84 'int main() { return (1 ? 2 : 3) * 42; }'
check conditional-as-if-condition 42 'int main() { if (1 ? 1 : 0) return 42; return 0; }'
check conditional-postincrement-condition 42 'int main() { int a = 1; return a++ ? 42 : 24; }'
check conditional-function-call-condition 42 'int one() { return 1; } int main() { return one() ? 42 : 24; }'
check pointer-dereference-local 42 'int main() { int x = 42; int *p; p = &x; return *p; }'
check pointer-init-address 42 'int main() { int x = 42; int *p = &x; return *p; }'
check pointer-init-copy 42 'int main() { int x = 42; int *p = &x; int *q = p; return *q; }'
check pointer-init-indirect-store 7 'int main() { int x = 42; int *p = &x; int **pp = &p; **pp = 7; return x; }'
check pointer-init-compound 42 'int main() { int x = 42; int *p = &x; return *(p += 0); }'
check pointer-store-updates-local 24 'int main() { int x = 42; int *p; p = &x; *p = 24; return x; }'
check pointer-assignment-copy 42 'int main() { int x = 42; int *p; int *q; p = &x; q = p; return *q; }'
check pointer-reassignment-target 42 'int main() { int a = 24; int b = 42; int *p; p = &a; p = &b; return *p; }'
check pointer-alias-store-visible 7 'int main() { int x = 42; int *p; int *q; p = &x; q = &x; *q = 7; return *p; }'
check pointer-read-modify-write 2 'int main() { int x = 1; int *p; p = &x; *p = *p + 1; return x; }'
check pointer-to-pointer-dereference 42 'int main() { int x = 42; int *p; int **pp; p = &x; pp = &p; return **pp; }'
check dereference-address-expression 42 'int main() { int x = 42; int *p; p = &x; return *(&x); }'
check pointer-self-assignment-through-dereference 42 'int main() { int x = 42; int *p; p = &x; *p = *p; return x; }'
# A scalar object permits pointer arithmetic up to one past its end.
check pointer-add 24 'int main() { int a = 24; int *p = &a; return *((p + 1) - 1); }'
check integer-add-pointer 24 'int main() { int a = 24; int *p = &a; return *((1 + p) - 1); }'
check pointer-subtract 42 'int main() { int a = 42; int *p = &a + 1; return *(p - 1); }'
check pointer-difference-positive 1 'int main() { int a; int *p = &a + 1; int *q = &a; return p - q; }'
check pointer-difference-negative 255 'int main() { int a; int *p = &a + 1; int *q = &a; return q - p; }'
check pointer-difference-scale 3 'int main() { int a; int *p = &a + 1; int *q = &a; return (p - q) * 3; }'
check pointer-difference-expression 6 'int main() { int a; int *p = &a + 1; int *q = &a; return (p - q) * 6; }'
check pointer-arithmetic-store 7 'int main() { int a = 24; int *p = &a + 1; *(p - 1) = 7; return a; }'
check pointer-postincrement 24 'int main() { int a = 24; int *p = &a; p++; p--; return *p; }'
check pointer-postdecrement 42 'int main() { int a = 42; int *p = &a + 1; p--; return *p; }'
check pointer-preincrement 24 'int main() { int a = 24; int *p = &a; ++p; --p; return *p; }'
check pointer-increment-roundtrip 6 'int main() { int a = 3; int *p = &a; int s = *p; p++; p--; return s + *p; }'
check comma-expression-right-value 42 'int main() { return 1, 42; }'
check comma-expression-assignment-sequence 42 'int main() { int a = 0; a = 1, a = a + 41; return a; }'
check comma-expression-for-init-and-post 6 'int main() { int i; int j; int n = 0; for (i = 0, j = 0; i < 3; i = i + 1, j = j + 1) n = n + i + j; return n; }'
check comma-below-assignment-precedence 1 'int main() { int a = 0; a = 1, 2; return a; }'
check comma-parenthesized-local-operands 42 'int main() { int a = 1; int b = 42; return (a, b); }'
check comma-in-conditional-true-arm 42 'int main() { int a = 0; return 1 ? a = 1, a + 41 : 0; }'
check comma-as-if-condition 42 'int main() { int a = 0; if (a = 1, a == 1) return 42; return 0; }'
check comma-return-assignment-sequence 42 'int main() { int a = 0; return a = 41, a + 1; }'
check switch-default-before-matching-case 42 'int main() { switch (0) { default: return -1; case 0: return 42; } return -1; }'
check comment-crlf 42 $'int main() { // comment\r\n return 42; }'
check comment-cr 42 $'int main() { // comment\r return 42; }'
check whitespace-ff 42 $'int\fmain() { return 42; }'
check whitespace-vt 42 $'int\vmain() { return 42; }'
check prototype-unamed-name 42 'int f(int); int f(int x) {return x;} int main() { return f(42); }'
check prototype-different-param-name 42 'int f(int y); int f(int x) {return x;} int main() { return f(42); }'
check prototype-unspecified-params 42 'int f(); int f(int x) {return x;} int main() {return f(42);}'

# Expression builders must preserve pointer types through nested expressions.
check conditional-pointer-type 42 'int main() { int x = 42; int y = 7; return *(1 ? &x : &y); }'
check comma-pointer-type 42 'int main() { int x = 42; return *(0, &x); }'
check assignment-pointer-type 42 'int main() { int x = 42; int *p; return *(p = &x); }'
check compound-pointer-type 42 'int main() { int x = 42; int *p; p = &x; return *(p += 0); }'
check postfix-pointer-type 42 'int main() { int x = 42; int *p; p = &x; return *p++; }'
check binary-pointer-type 0 'int main() { int x; return (&x + 0) - &x; }'

# Compound assignments preserve one target address and the operation's type.
for entry in '+= 20 22 42' '-= 50 8 42' '*= 6 7 42' '/= 84 2 42' \
             '%= 85 43 42' '<<= 21 1 42' '>>= 84 1 42' \
             '&= 63 42 42' '^= 43 1 42' '|= 40 2 42'; do
    read -r op initial rhs expected <<< "$entry"
    check "compound-dereference-$op" 1 "int main(void) { int x = $initial; int *p = &x; return (*p $op $rhs) == $expected && x == $expected; }"
    check "compound-subscript-$op" 1 "int main(void) { int a[2]; a[0] = $initial; a[1] = 99; return (a[0] $op $rhs) == $expected && a[0] == $expected && a[1] == 99; }"
    for target in s.x 'p->x'; do
        check "compound-member-$target-$op" 1 "struct S { int x; int guard; }; int main(void) { struct S s; struct S *p = &s; s.x = $initial; s.guard = 99; return ($target $op $rhs) == $expected && s.x == $expected && s.guard == 99; }"
    done
done
for spec in 'char' 'unsigned char' 'short' 'unsigned short' 'int' 'unsigned' 'long' 'unsigned long' 'long long' 'unsigned long long'; do
    check "compound-store-width-$spec" 1 "struct S { char before; $spec x; char after; }; int main(void) { struct S s; $spec *p = &s.x; s.before = 7; s.x = 20; s.after = 9; return (*p += 22) == 42 && s.x == 42 && s.before == 7 && s.after == 9; }"
done
check compound-member-char-narrowing 1 'struct S { char x; unsigned char y; }; int main(void) { struct S s; s.x = 127; s.y = 255; return (s.x += 1) == -128 && s.x == -128 && (s.y += 1) == 0 && s.y == 0; }'
check compound-short-narrowing 1 'int main(void) { short a[2]; a[0] = 32767; a[1] = -32768; return (a[0] += 1) == -32768 && (a[1] -= 1) == 32767 && a[0] == -32768 && a[1] == 32767; }'
check compound-unsigned-short-narrowing 1 'int main(void) { unsigned short a[1]; a[0] = 65535; return (a[0] += 1) == 0 && (a[0] -= 1) == 65535; }'
check compound-unsigned-calculation 1 'struct S { int x; }; int main(void) { struct S s; s.x = -1; return (s.x /= 2U) == 2147483647 && s.x == 2147483647; }'
check compound-wide-signed-calculation 1 'struct S { long x; }; int main(void) { struct S s; s.x = -9; return (s.x /= 2U) == -4 && s.x == -4; }'
check compound-widen-before-division 1 'int main(void) { int a[1]; a[0] = 9; return (a[0] /= 4294967297L) == 0 && a[0] == 0; }'
check compound-wide-unsigned-before-narrowing 1 'int main(void) { int a[1]; a[0] = -1; return (a[0] /= 2UL) == -1 && a[0] == -1; }'
check compound-char-integer-promotion 1 'int main(void) { char a[1]; a[0] = -9; return (a[0] /= 2U) == -5 && a[0] == -5; }'
check compound-short-wide-conversion 1 'int main(void) { short a[1]; a[0] = -9; return (a[0] /= 2UL) == -5 && a[0] == -5; }'
check compound-unsigned-short-promotion 1 'int main(void) { unsigned short a[1]; a[0] = 65535; return (a[0] /= -1) == 1 && a[0] == 1; }'
check compound-shift-left-type 1 'int main(void) { unsigned a[1]; a[0] = 2147483648U; return (a[0] <<= 1ULL) == 0 && a[0] == 0; }'
check compound-shift-independent-promotions 1 'int main(void) { long a[1]; a[0] = -8; return (a[0] >>= 1ULL) == -4 && a[0] == -4; }'
check compound-wide-members 1 'struct S { long long x; unsigned long long y; }; int main(void) { struct S s; s.x = 1LL << 40; s.y = 1ULL << 63; return (s.x *= 3) == 3LL << 40 && (s.y >>= 1) == 1ULL << 62; }'
check compound-wide-unsigned-divmod 1 'int main(void) { unsigned long long a[1]; a[0] = 18446744073709551615ULL; return (a[0] /= 2) == 9223372036854775807ULL && (a[0] %= 7) == 0; }'
check compound-index-evaluated-once 1 'int main(void) { int a[2]; a[0] = 20; a[1] = 99; int i = 0; int result = (a[i++] += 22); return result == 42 && i == 1 && a[0] == 42 && a[1] == 99; }'
check compound-pointer-base-evaluated-once 1 'int main(void) { int a[2]; a[0] = 20; a[1] = 99; int *p = a; int result = (*p++ += 22); return result == 42 && p == a + 1 && a[0] == 42 && a[1] == 99; }'
check compound-call-base-evaluated-once 1 'struct S { int x; }; struct S *get(struct S *p, int *n) { (*n)++; return p; } int main(void) { struct S s; s.x = 14; int n = 0; int result = (get(&s, &n)->x *= 3); return result == 42 && n == 1 && s.x == 42; }'
check compound-both-operands-call 1 'int *get(int *p, int *n) { (*n)++; return p; } int value(int *n) { (*n)++; return 22; } int main(void) { int x = 20; int n = 0; int m = 0; int result = (*get(&x, &n) += value(&m)); return result == 42 && x == 42 && n == 1 && m == 1; }'
check compound-nested-assignment 1 'struct S { int x; }; int main(void) { struct S s; int a[1]; s.x = 0; a[0] = 7; return (s.x += (a[0] *= 6)) == 42 && s.x == 42 && a[0] == 42; }'
check compound-result-in-binary-expression 1 'int main(void) { int a[1]; a[0] = 20; int *p = &(a[0]); return 10 + (*p += 22) == 52 && a[0] == 42; }'
check compound-pointer-member-scaling 1 'struct S { int *p; }; int main(void) { struct S s; int a[3]; s.p = a; return (s.p += 2) == a + 2 && s.p == a + 2 && (s.p -= 1) == a + 1; }'
check compound-pointer-array-element 42 'int main(void) { int a[3]; a[1] = 42; int *p[1]; p[0] = a; p[0] += 2; return *(p[0] -= 1); }'
check compound-pointer-through-dereference 42 'int main(void) { int a[3]; a[2] = 42; int *p = a; int **pp = &p; *pp += 2; return **pp; }'
check compound-struct-pointer-scaling 1 'struct S { char c; long x; }; int main(void) { struct S a[3]; struct S *p = a; struct S **pp = &p; return (*pp += 2) == a + 2 && (*pp -= 1) == a + 1; }'
check compound-negative-pointer-offset 42 'int main(void) { int a[3]; a[1] = 42; int *p = a + 2; int **pp = &p; char offset = -1; *pp += offset; return *p; }'
check compound-array-member-index-once 1 'struct S { int a[2]; }; int main(void) { struct S s; s.a[0] = 20; s.a[1] = 99; int i = 0; return (s.a[i++] += 22) == 42 && i == 1 && s.a[1] == 99; }'
check compound-nested-array-member 42 'struct S { int x; }; struct O { struct S s[2]; }; int main(void) { struct O o; o.s[1].x = 14; o.s[1].x *= 3; return o.s[1].x; }'
check compound-stack-calls-and-outer-push 1 'int rhs(int a, int b, int c, int d, int e, int f, int g) { return g; } int *get(int a, int b, int c, int d, int e, int f, int *p) { return p; } int main(void) { int x = 20; return 10 + (*get(0,0,0,0,0,0,&x) += rhs(0,0,0,0,0,0,22)) == 52 && x == 42; }'
check compound-call-arguments 1 'int take(int a, int b, int c, int d, int e, int f, int g) { return a + g; } int main(void) { int a[2]; a[0] = 20; a[1] = 14; return take(a[0] += 22,0,0,0,0,0,a[1] *= 3) == 84 && a[0] == 42 && a[1] == 42; }'

check_error compound-pointer-plus-pointer 'int main(void) { int a[2]; int *p = a; int *q = a; p += q; return 0; }' '1:54: error: invalid operands to binary +'
check_error compound-pointer-minus-pointer 'int main(void) { int a[2]; int *p = a; int *q = a; p -= q; return 0; }' '1:54: error: incompatible assignment type'
check_error compound-integer-plus-pointer 'int main(void) { int a[1]; int x = 0; x += a; return 0; }' '1:41: error: incompatible assignment type'
check_error compound-pointer-multiply 'int main(void) { int a[1]; int *p = a; p *= 2; return 0; }' '1:42: error: invalid operands to integer operator'
check_error compound-pointer-shift 'int main(void) { int a[1]; int *p = a; p <<= 1; return 0; }' '1:42: error: invalid operands to integer operator'
check_error compound-pointer-member-void 'struct S { void *p; }; int main(void) { struct S s; s.p += 1; return 0; }' '1:57: error: pointer arithmetic on void pointer'
check_error compound-pointer-member-incomplete 'struct S { struct T *p; }; int main(void) { struct S s; s.p += 1; return 0; }' '1:61: error: pointer arithmetic on incomplete type'
check_error compound-array-member-target 'struct S { int a[2]; }; int main(void) { struct S s; s.a += 1; return 0; }' '1:58: error: invalid assignment target'
check_error compound-struct-target 'struct S { int x; }; int main(void) { struct S s; s += 1; return 0; }' '1:51: error: struct values are not supported yet'
check_error compound-result-is-not-lvalue 'int main(void) { int a = 0; (a += 1) += 1; return 0; }' '1:38: error: invalid assignment target'
check_error compound-result-address 'int main(void) { int a = 0; int *p = &(a += 1); return 0; }' '1:38: error: invalid address-of target'
check_error compound-result-not-null-constant 'int main(void) { int a = 0; int *p = (a += 0); return 0; }' '1:34: error: incompatible initializer type'
check_error compound-member-void-rhs 'void f(void); struct S { int x; }; int main(void) { struct S s; s.x += f(); return 0; }' '1:72: error: void expression used as a value'

# sizeof keeps array types and does not evaluate expression operands.
for entry in 'char:1' 'unsigned char:1' 'short:2' 'short int:2' \
             'unsigned short int:2' 'int:4' 'unsigned:4' 'int unsigned:4' \
             'long:8' 'unsigned long int:8' 'long long:8' \
             'unsigned long long int:8'; do
    spec=${entry%:*}
    size=${entry##*:}
    check "sizeof-type-$spec" "$size" "int main(void) { return sizeof($spec); }"
    check "sizeof-variable-$spec" "$size" "int main(void) { $spec x; return sizeof x; }"
done
check sizeof-void-pointer 8 'int main(void) { return sizeof(void *); }'
check sizeof-pointer-to-pointer 8 'int main(void) { return sizeof(int **); }'
check sizeof-incomplete-pointer 8 'struct S; int main(void) { return sizeof(struct S *); }'
check sizeof-array-type 12 'int main(void) { return sizeof(int [3]); }'
check sizeof-array-of-pointers-type 24 'int main(void) { return sizeof(char *[3]); }'
check sizeof-large-array-type 1 'int main(void) { return sizeof(char [2147483647]) == 2147483647UL; }'
check sizeof-array-expression 12 'int main(void) { int a[3]; return sizeof a; }'
check sizeof-parenthesized-array 12 'int main(void) { int a[3]; return sizeof((a)); }'
check sizeof-dereferenced-array-address 12 'int main(void) { int a[3]; return sizeof *(&a); }'
check sizeof-decayed-array-expression 8 'int main(void) { int a[3]; return sizeof(a + 0); }'
check sizeof-comma-array-conversion 8 'int main(void) { int a[3]; return sizeof(0, a); }'
check sizeof-string-literal 4 'int main(void) { return sizeof "abc"; }'
check sizeof-parenthesized-string 4 'int main(void) { return sizeof("abc"); }'
check sizeof-concatenated-string 4 'int main(void) { return sizeof "a" "bc"; }'
check sizeof-string-embedded-zero 4 'int main(void) { return sizeof "a\0b"; }'
check sizeof-empty-string 1 'int main(void) { return sizeof ""; }'
check sizeof-character-constant 4 "int main(void) { return sizeof 'a'; }"
check sizeof-struct-type 16 'struct S { char c; long n; }; int main(void) { return sizeof(struct S); }'
check sizeof-struct-expression 16 'struct S { char c; long n; }; int main(void) { struct S s; return sizeof s; }'
check sizeof-anonymous-struct 16 'int main(void) { return sizeof(struct { char c; long n; }); }'
check sizeof-inline-tag-definition 16 'int main(void) { return sizeof(struct S { char c; long n; }); }'
check sizeof-type-tag-visibility 1 'int main(void) { sizeof(struct S { long x; }); struct S s; return sizeof s == 8; }'
check sizeof-struct-members 1 'struct I { char c; long n; }; struct S { char c; struct I inner; int a[3]; }; int main(void) { struct S s; return sizeof s == 40 && sizeof s.inner == 16 && sizeof s.a == 12 && sizeof s.a[0] == 4; }'
check sizeof-null-pointer-members 1 'struct S { char c; int a[3]; }; int main(void) { struct S *p = 0; return sizeof p->c == 1 && sizeof p->a == 12 && sizeof *p == 16; }'
check sizeof-array-parameter-is-pointer 8 'int f(int a[3]) { return sizeof a; } int main(void) { int a[3]; return f(a); }'
check sizeof-expression-promotions 1 'int main(void) { char c; return sizeof c == 1 && sizeof(c + 0) == 4 && sizeof ~c == 4 && sizeof !c == 4; }'
check sizeof-postincrement-unevaluated 1 'int main(void) { int i = 0; return sizeof(i++) == 4 && i == 0; }'
check sizeof-preincrement-unevaluated 1 'int main(void) { char c = 0; return sizeof ++c == 1 && c == 0; }'
check sizeof-assignment-unevaluated 1 'int main(void) { int i = 0; return sizeof(i = 42) == 4 && i == 0; }'
check sizeof-compound-assignment-unevaluated 1 'int main(void) { short a[2]; int i = 0; return sizeof(a[i++] += 42) == 2 && i == 0; }'
check sizeof-subscript-unevaluated 1 'int main(void) { int a[2]; int i = 0; return sizeof a[i++] == 4 && i == 0; }'
check sizeof-pointer-increment-unevaluated 1 'int main(void) { int a[2]; int *p = a; return sizeof *p++ == 4 && p == a; }'
check sizeof-null-dereference-unevaluated 1 'int main(void) { int *p = 0; return sizeof *p == 4; }'
check sizeof-division-not-evaluated 4 'int main(void) { return sizeof(1 / 0); }'
check sizeof-overflow-not-evaluated 8 'int main(void) { return sizeof(9223372036854775807L + 1L); }'
check sizeof-call-unevaluated 1 'int f(int *p) { (*p)++; return 42; } int main(void) { int n = 0; return sizeof f(&n) == 4 && n == 0; }'
check sizeof-call-no-link-reference 1 'char external(void); int main(void) { return sizeof external(); }'
check sizeof-member-call-unevaluated 4 'struct S { int x; }; struct S *external(void); int main(void) { return sizeof external()->x; }'
check sizeof-result-width 8 'int main(void) { return sizeof sizeof(char); }'
check sizeof-result-unsigned 1 'int main(void) { return sizeof(int) > 0 && sizeof(int) < -1; }'
check sizeof-type-precedence 6 'int main(void) { return sizeof(int) + 2; }'
check sizeof-unary-precedence 8 'int main(void) { return sizeof 1 + sizeof 2; }'
check sizeof-array-bound 1 'int main(void) { int a[sizeof(int)]; a[3] = 42; return sizeof a == 16 && a[3] == 42; }'
check sizeof-case-constant 42 'int main(void) { switch (4) { case sizeof(int): return 42; } return 0; }'
check sizeof-nested-expressions 1 'int main(void) { int a[2]; return sizeof(sizeof a) == 8 && sizeof(a[0]++) == 4; }'

check_error sizeof-void 'int main(void) { return sizeof(void); }' '1:25: error: sizeof cannot be applied to void'
check_error sizeof-void-expression 'void f(void); int main(void) { return sizeof f(); }' '1:39: error: sizeof cannot be applied to void'
check_error sizeof-incomplete-struct 'struct S; int main(void) { return sizeof(struct S); }' '1:35: error: sizeof cannot be applied to an incomplete type'
check_error sizeof-incomplete-dereference 'int main(void) { struct S *p; return sizeof *p; }' '1:38: error: sizeof cannot be applied to an incomplete type'
check_error sizeof-named-type 'int main(void) { return sizeof(int x); }' '1:36: error: type name cannot contain an identifier'
check_error sizeof-named-pointer-type 'int main(void) { return sizeof(int *x); }' '1:37: error: type name cannot contain an identifier'
check_error sizeof-named-array-type 'int main(void) { return sizeof(int x[2]); }' '1:36: error: type name cannot contain an identifier'
check_error sizeof-empty-operand 'int main(void) { return sizeof(); }' '1:32: error: expect expr'
check_error sizeof-missing-operand 'int main(void) { return sizeof; }' '1:31: error: expect expr'
check_error sizeof-type-without-parens 'int main(void) { return sizeof int; }' '1:32: error: expect expr'
check_error sizeof-missing-rparen 'int main(void) { return sizeof(int; }' '1:35: error: expect '\'')'\'''
check_error sizeof-missing-array-rbracket 'int main(void) { return sizeof(int[2); }' '1:37: error: expect '\'']'\'''
check_error sizeof-incomplete-array 'int main(void) { return sizeof(int[]); }' '1:25: error: sizeof cannot be applied to an incomplete type'
check_error sizeof-void-array 'int main(void) { return sizeof(void[2]); }' '1:36: error: array element has void type'
check_error sizeof-incomplete-struct-array 'int main(void) { return sizeof(struct S[2]); }' '1:40: error: array element has incomplete type'
check_error sizeof-zero-array-bound 'int main(void) { return sizeof(int[0]); }' '1:36: error: array bound must be positive'
check_error sizeof-variable-array-bound 'int main(void) { int n = 3; return sizeof(int[n]); }' '1:48: error: not an integer constant expression'
check_error sizeof-undeclared-operand 'int main(void) { return sizeof missing; }' '1:32: error: undeclared identifier'
check_error sizeof-invalid-assignment-operand 'int main(void) { return sizeof(1 = 2); }' '1:34: error: invalid assignment target'
check_error sizeof-missing-member 'struct S { int x; }; int main(void) { struct S s; return sizeof s.y; }' '1:67: error: no member named '\''y'\'' in struct'
check_error sizeof-invalid-call 'int f(int x); int main(void) { return sizeof f(); }' '1:46: error: wrong number of arguments to function '\''f'\'''
check_error sizeof-multiline-void $'int main(void) {\n  return sizeof(void);\n}\n' '2:10: error: sizeof cannot be applied to void'
check_error sizeof-multiline-type-name $'int main(void) {\n  return sizeof(int name);\n}\n' '2:21: error: type name cannot contain an identifier'

# Enum constants are int; enum objects use our signed int representation.
check enum-basic 6 'enum Color { RED, GREEN = 5, BLUE }; int main(void) { enum Color color = BLUE; return color; }'
check enum-default-values 1 'enum { A, B, C }; int main(void) { return A == 0 && B == 1 && C == 2; }'
check enum-duplicate-values 1 'enum { A = 5, B = 5, C }; int main(void) { return A == B && C == 6; }'
check enum-negative-values 1 'enum E { A = -2, B, C, D }; int main(void) { return A == -2 && B == -1 && C == 0 && D == 1; }'
check enum-local-anonymous-trailing-comma 42 'int main(void) { enum { ANSWER = 42, }; return ANSWER; }'
check enum-constant-expression 42 'enum E { A = 1, B = (A << 5) | 10 }; int main(void) { return B; }'
check enum-reference-and-conditional 42 'enum { A = 2, B = A * 21, C = A ? B : 0 }; int main(void) { return C; }'
check enum-sizeof-initializer 4 'enum { SIZE = sizeof(int) }; int main(void) { return SIZE; }'
check enum-int-boundaries 1 'enum { A = 2147483647, B = -2147483648, C = 0 }; int main(void) { return A == 2147483647 && B == -2147483648 && C == 0; }'
check enum-max-final-value 1 'enum { A = 2147483647, }; int main(void) { return A == 2147483647; }'
check enum-constant-has-int-type 1 'enum { A = 0 }; int main(void) { return sizeof A == 4 && A - 1 < 0; }'
check enum-zero-null-pointer-constant 1 'enum { ZERO }; int main(void) { int *p = ZERO; return p == 0; }'
check enum-array-bound 42 'enum { COUNT = 3 }; int main(void) { int a[COUNT]; a[COUNT - 1] = 42; return a[2]; }'
check enum-switch 42 'enum E { A = 1, B = 42 }; int main(void) { enum E e = A; switch (e) { case A: return B; default: return 0; } }'
check enum-for-variable 1 'enum E { A = -1, B = 0, C = 3 }; int main(void) { int sum = 0; for (enum E e = B; e <= C; e++) sum += e; return sum == 6; }'
check enum-function-signature 42 'enum E { A = -1, B = 42 }; enum E id(enum E x) { return x; } int main(void) { return id(B); }'
check enum-return-sign-extension 1 'enum E { A = -1 }; enum E f(void) { return A; } int main(void) { long x = f(); return x == -1 && f() < 0; }'
check enum-stack-parameter 1 'enum E { A = -1 }; enum E f(int a, int b, int c, int d, int e, int f, enum E g) { return g; } int main(void) { return f(0,0,0,0,0,0,A) == -1; }'
check enum-array-storage 1 'enum E { A = -1, B = 42 }; int main(void) { enum E a[2]; a[0] = A; a[1] = B; enum E *p = a; return p[0] == -1 && p[1] == 42 && sizeof a == 8; }'
check enum-struct-member 1 'enum E { A = -1, B = 42 }; struct S { char c; enum E e; char end; }; int main(void) { struct S s; s.c = 7; s.e = B; s.end = 9; return s.e == 42 && s.c == 7 && s.end == 9 && sizeof s == 12; }'
check enum-compound-and-increment 1 'enum E { A = -1, B = 42 }; int main(void) { enum E e = A; return (e += 43) == B && e-- == B && e == 41 && ++e == B; }'
check enum-integer-conversion 1 'enum E { A = -1 }; int main(void) { enum E e = 4294967295UL; return e == -1 && (e = 4294967295UL) == -1; }'
check enum-compatible-int-pointer 42 'enum E { A = -1, B = 42 }; int main(void) { enum E e = B; int *p = &e; return *p; }'
check enum-compatible-int-prototype 42 'enum E { A = -1, B = 42 }; int f(enum E); int f(int x) { return x; } int main(void) { return f(B); }'
check enum-default-argument-promotion 42 'enum E { A = -1, B = 42 }; int f(); int f(enum E x) { return x; } int main(void) { enum E e = B; return f(e); }'
check enum-unprototyped-call-promotion 1 'enum E { A = -1 }; int f(); int main(void) { enum E e = A; return f(e); } int f(int x) { return x == -1; }'
check enum-tag-redeclaration 42 'enum E { A = 42 }; enum E; int main(void) { enum E e = A; return e; }'
check enum-tag-and-enumerator-namespace 42 'enum E { E = 42 }; int main(void) { enum E e = E; return e; }'
check enum-shadow-variable 42 'enum { A = 42 }; int main(void) { int A = 7; { enum { A = 42 }; if (A != 42) return 0; } return A == 7 ? 42 : 0; }'
check enum-initializer-sees-outer-constant 42 'enum { A = 7 }; int main(void) { { enum { A = A + 35 }; if (A != 42) return 0; } return A == 7 ? 42 : 0; }'
check enum-variable-shadows-constant 42 'enum { A = 7 }; int main(void) { int A = 42; return A; }'
check enum-parameter-shadows-global-constant 42 'enum { A = 7 }; int f(int A) { return A; } int main(void) { return f(42); }'
check enum-tag-and-constant-shadowing 42 'enum E { A = 7 }; int main(void) { { enum E { A = 42 }; enum E e = A; if (e != 42) return 0; } enum E e = A; return e == 7 ? 42 : 0; }'
check enum-sibling-scopes 42 'int main(void) { { enum E { A }; } { enum E { A = 42 }; return A; } }'
check enum-function-scope-restore 42 'int first(void) { enum { A = 1 }; return A; } int main(void) { enum { A = 42 }; return A; }'
check enum-for-scope-restore 42 'int main(void) { for (enum { A = 1 } e = A; e < 2; e++) {} enum { A = 42 }; return A; }'
check enum-parameter-definition-scope 42 'int f(enum E { A = 42 } e) { enum E x = e; return x + A - 42; } int main(void) { enum E { A = 1 } e = A; return f(42); }'
check enum-prototype-scope-restore 42 'int f(enum E { A = 1 } e); int main(void) { enum E { A = 42 } e = A; return e; }'
check enum-definition-in-struct 42 'struct S { enum E { A = 42 } e; }; int main(void) { struct S s; enum E e = A; s.e = e; return s.e; }'
check enum-ordinary-and-member-names 42 'int main(void) { enum E { A = 42 } e = A; { struct E { int x; }; struct E s; s.x = e; return s.x; } }'
check enum-member-namespace 42 'enum { A = 42 }; struct S { int A; }; int main(void) { struct S s; s.A = A; return s.A; }'
check enum-label-namespace 42 'enum { A = 42 }; int main(void) { goto A; return 0; A: return A; }'
check enum-definition-in-type-name 42 'int main(void) { return sizeof(enum E { A = 42 }) == 4 ? A : 0; }'
check enum-sizeof 1 'enum E { A = -1, B = 42 }; int main(void) { return sizeof(enum E) == 4 && sizeof(A) == sizeof(int); }'
check enum-short-circuit-constant-expression 1 'enum { A = 0 && (1 / 0), B = 1 ? 42 : (1 / 0) }; int main(void) { return A == 0 && B == 42; }'

check_error enum-empty 'enum E {};' '1:9: error: expect enumerator name'
check_error enum-anonymous-empty 'enum {};' '1:7: error: expect enumerator name'
check_error enum-missing-tag 'enum;' '1:5: error: expect enum tag or '\''{'\'''
check_error enum-missing-enumerator 'enum E { A, , B };' '1:13: error: expect enumerator name'
check_error enum-keyword-enumerator 'enum E { int };' '1:10: error: expect enumerator name'
check_error enum-missing-initializer 'enum E { A = };' '1:14: error: expect expr'
check_error enum-missing-comma 'enum E { A B };' '1:12: error: expect '\''}'\'''
check_error enum-missing-rbrace 'enum E { A;' '1:11: error: expect '\''}'\'''
check_error enum-eof 'enum E { A' '1:11: error: expect '\''}'\'''
check_error enum-duplicate-name 'enum E { A, A };' '1:13: error: duplicate enumerator '\''A'\'''
check_error enum-duplicate-across-definitions 'enum E { A }; enum F { A };' '1:24: error: duplicate enumerator '\''A'\'''
check_error enum-redefinition 'enum E { A }; enum E { B };' '1:20: error: redefinition of enum '\''E'\'''
check_error enum-undefined-tag 'int main(void) { enum E e; return 0; }' '1:23: error: enum '\''E'\'' is not defined'
check_error enum-forward-declaration 'enum E;' '1:6: error: enum '\''E'\'' is not defined'
check_error enum-self-type-incomplete 'enum E { A = sizeof(enum E) };' '1:26: error: enum '\''E'\'' is not defined'
check_error enum-struct-tag-conflict 'struct E { int x; }; enum E { A };' '1:27: error: tag '\''E'\'' declared as a different kind'
check_error enum-tag-struct-conflict 'enum E { A }; struct E { int x; };' '1:22: error: tag '\''E'\'' declared as a different kind'
check_error enum-struct-reference-conflict 'enum E { A }; int main(void) { struct E *p; return 0; }' '1:39: error: tag '\''E'\'' declared as a different kind'
check_error enum-reference-struct-conflict 'struct E { int x; }; int main(void) { enum E e; return 0; }' '1:44: error: tag '\''E'\'' declared as a different kind'
check_error enum-outside-block 'int main(void) { { enum { A }; } return A; }' '1:41: error: undeclared identifier'
check_error enum-outside-function 'int f(void) { enum { A }; return A; } int main(void) { return A; }' '1:63: error: undeclared identifier'
check_error enum-outside-for 'int main(void) { for (enum { A } e = A; e < 1; e++) {} return A; }' '1:63: error: undeclared identifier'
check_error enum-tag-outside-block 'int main(void) { { enum E { A }; } enum E e; return 0; }' '1:41: error: enum '\''E'\'' is not defined'
check_error enum-param-tag-outside-prototype 'int f(enum E { A } e); int main(void) { enum E e; return 0; }' '1:46: error: enum '\''E'\'' is not defined'
check_error enum-param-constant-outside-prototype 'int f(enum E { A } e); int main(void) { return A; }' '1:48: error: undeclared identifier'
check_error enum-variable-name-conflict 'int main(void) { int A; enum { A }; return 0; }' '1:32: error: enumerator conflicts with variable '\''A'\'''
check_error enum-name-variable-conflict 'int main(void) { enum { A }; int A; return 0; }' '1:34: error: variable conflicts with enumerator '\''A'\'''
check_error enum-parameter-name-conflict 'int f(int A) { enum { A }; return 0; }' '1:23: error: enumerator conflicts with variable '\''A'\'''
check_error enum-name-parameter-conflict 'int f(enum { A } A);' '1:18: error: parameter conflicts with enumerator '\''A'\'''
check_error enum-previous-parameter-conflict 'int f(int A, enum { A } x);' '1:21: error: enumerator conflicts with variable '\''A'\'''
check_error enum-function-name-conflict 'int f(void); enum { f };' '1:21: error: enumerator conflicts with function '\''f'\'''
check_error enum-name-function-conflict 'enum { f }; int f(void);' '1:17: error: function conflicts with enumerator '\''f'\'''
check_error enum-constant-call 'enum { A }; int main(void) { return A(); }' '1:37: error: called object is not a function'
check_error enum-shadow-function-call 'int f(void); int main(void) { enum { f }; return f(); }' '1:50: error: called object is not a function'
check_error enum-constant-assignment 'enum { A }; int main(void) { A = 1; return 0; }' '1:32: error: invalid assignment target'
check_error enum-constant-increment 'enum { A }; int main(void) { A++; return 0; }' '1:31: error: invalid increment target'
check_error enum-constant-address 'enum { A }; int main(void) { int *p = &A; return 0; }' '1:39: error: invalid address-of target'
check_error enum-too-large 'enum { A = 2147483648L };' '1:8: error: enumerator value is outside the range of int'
check_error enum-too-small 'enum { A = -2147483649L };' '1:8: error: enumerator value is outside the range of int'
check_error enum-unsigned-too-large 'enum { A = 4294967295U };' '1:8: error: enumerator value is outside the range of int'
check_error enum-unsigned-high-bit 'enum { A = 18446744073709551615ULL };' '1:8: error: enumerator value is outside the range of int'
check_error enum-implicit-overflow 'enum { A = 2147483647, B };' '1:24: error: enumerator value is outside the range of int'
check_error enum-noninteger-initializer 'enum { A = "text" };' '1:12: error: enumerator value must have integer type'
check_error enum-nonconstant-initializer 'int main(void) { int x = 1; enum { A = x }; return 0; }' '1:42: error: not an integer constant expression'
check_error enum-self-reference 'enum { A = A };' '1:12: error: undeclared identifier'
check_error enum-division-by-zero 'enum { A = 1 / 0 };' '1:18: error: division by zero in constant expression'
check_error enum-incompatible-pointers 'enum E { A = -1 }; enum F { B = -2 }; int main(void) { enum E *e; enum F *f = e; return 0; }' '1:75: error: incompatible initializer type'
check_error enum-incompatible-prototypes 'enum E { A = -1 }; enum F { B = -2 }; int f(enum E); int f(enum F);' '1:58: error: conflicting declaration of function '\''f'\'''
check_error enum-syntax-location $'enum E {\n  A,\n  ,\n};\n' '3:3: error: expect enumerator name'
check_error enum-duplicate-location $'enum E {\n  A,\n  A\n};\n' '3:3: error: duplicate enumerator '\''A'\'''
check_error enum-range-location $'enum E {\n  A = 2147483648L\n};\n' '2:3: error: enumerator value is outside the range of int'

# Parameters and outermost body declarations share depth 1; nested blocks shadow.
check parameter-nested-variable-shadow 42 'int f(int x) { { int x = 7; if (x != 7) return 0; } return x; } int main(void) { return f(42); }'
check parameter-nested-enumerator-shadow 42 'int f(int x) { { enum { x = 7 }; if (x != 7) return 0; } return x; } int main(void) { return f(42); }'
check parameter-for-variable-shadow 42 'int f(int x) { for (int x = 0; x < 2; x++) {} return x; } int main(void) { return f(42); }'
check parameter-enumerator-nested-variable-shadow 42 'int f(enum { A = 7 } x) { { int A = 42; return A; } } int main(void) { return f(0); }'
check parameter-prototype-scope-restored 42 'int f(int x); enum { x = 42 }; int main(void) { return x; }'
check parameter-definition-scope-restored 42 'int f(int x) { int y = 0; return x + y; } enum { x = 40, y = 2 }; int main(void) { return x + y; }'

# Typed functions preserve pointer widths and check complete signatures.
check typed-pointer-identity 42 'int *identity(int *p) { return p; } int main(void) { int x = 42; return *identity(&x); }'
check typed-pointer-prototype 42 'int *identity(int *); int main(void) { int x = 42; return *identity(&x); } int *identity(int *p) { return p; }'
check typed-nested-pointer 42 'int **identity(int **p) { return p; } int main(void) { int x = 42; int *p = &x; return **identity(&p); }'
check typed-mixed-parameters 42 'int get(int *p, int n) { return *p + n; } int main(void) { int x = 43; return get(&x, -1); }'
check typed-six-registers 42 'int get(int *a, int b, int *c, int d, int *e, int f) { return *a + b + *c + d + *e + f; } int main(void) { int x = 10; return get(&x, 1, &x, 2, &x, 9); }'
check typed-void-return 42 'void set(int *p, int n) { *p = n; return; } int main(void) { int x = 0; set(&x, 42); return x; }'
check typed-void-fallthrough 42 'void set(int *p) { *p = 42; } int main(void) { int x = 0; set(&x); return x; }'
check typed-null-return 1 'int *nothing(void) { return 0; } int main(void) { return nothing() == 0; }'
check typed-null-argument 1 'int isnull(int *p) { return p == 0; } int main(void) { return isnull(1 - 1); }'
check typed-void-pointer-conversion 42 'void *identity(void *p) { return p; } int main(void) { int x = 42; int *p = identity(&x); return *p; }'
check typed-void-pointer-argument 42 'int *identity(int *p) { return p; } int main(void) { int x = 42; void *p = &x; return *identity(p); }'
check typed-nested-calls 42 'int *identity(int *p) { return p; } int main(void) { int x = 42; return *identity(identity(&x)); }'
check typed-pointer-recursion 42 'int *walk(int *p, int n) { if (n) return walk(p, n - 1); return p; } int main(void) { int x = 42; return *walk(&x, 3); }'
check typed-unspecified-prototype 42 'int *identity(); int main(void) { int x = 42; return *identity(&x); } int *identity(int *p) { return p; }'
check typed-compatible-redeclarations 42 'int *identity(int *); int *identity(int *value); int *identity(int *p) { return p; } int main(void) { int x = 42; return *identity(&x); }'
check typed-preserve-prototype 42 'int *identity(int *p) { return p; } int *identity(); int main(void) { int x = 42; return *identity(&x); }'
check typed-null-conditional 42 'int *choose(int *p) { return 0 ? 0 : p; } int main(void) { int x = 42; return *choose(&x); }'
check typed-discard-void 42 'void noop(void) { return; } int main(void) { noop(), noop(); 1 ? noop() : noop(); return 42; }'
check_error typed-conflicting-return 'int *f(int *p); int f(int *p);' '1:21: error: conflicting declaration of function '\''f'\'''
check_error typed-conflicting-parameter 'int f(int *p); int f(int p);' '1:20: error: conflicting declaration of function '\''f'\'''
check_error typed-conflicting-pointer-depth 'int f(int **); int f(int *);' '1:20: error: conflicting declaration of function '\''f'\'''
check_error typed-conflicting-void-pointer 'int f(void *); int f(int *);' '1:20: error: conflicting declaration of function '\''f'\'''
check_error typed-nonzero-pointer-argument 'int f(int *p) { return 0; } int main(void) { return f(1); }' '1:55: error: incompatible argument type'
check_error typed-variable-zero-argument 'int f(int *p) { return 0; } int main(void) { int x = 0; return f(x); }' '1:66: error: incompatible argument type'
check_error typed-pointer-to-int-argument 'int f(int n) { return n; } int main(void) { int x = 0; return f(&x); }' '1:65: error: incompatible argument type'
check_error typed-wrong-pointer-depth-argument 'int f(int **p) { return 0; } int main(void) { int *p = 0; return f(p); }' '1:68: error: incompatible argument type'
check_error typed-nonzero-pointer-return 'int *f(void) { return 1; }' '1:16: error: incompatible return type'
check_error typed-pointer-to-int-return 'int f(int *p) { return p; }' '1:17: error: incompatible return type'
check_error typed-void-return-value 'void f(void) { return 1; }' '1:16: error: return with a value in void function'
check_error typed-void-value-return 'void f(void) {} int main(void) { return f(); }' '1:41: error: void expression used as a value'
check_error typed-void-initializer 'void f(void) {} int main(void) { int x = f(); return 0; }' '1:42: error: void expression used as a value'
check_error typed-void-condition 'void f(void) {} int main(void) { if (f()) return 1; return 0; }' '1:38: error: void expression used as a value'
check_error typed-void-arithmetic 'void f(void) {} int main(void) { return f() + 1; }' '1:41: error: void expression used as a value'
check_error typed-void-variable 'int main(void) { void x; return 0; }' '1:23: error: variable has void type'
check_error typed-void-parameter 'int f(void x);' '1:12: error: parameter has void type'
check_error typed-pointer-arity 'int f(int *); int main(void) { return f(); }' '1:39: error: wrong number of arguments to function '\''f'\'''
check_error typed-deferred-argument 'int f(); int main(void) { return f(1); } int f(int *p) { return 0; }' '1:36: error: incompatible argument type'
check_error typed-void-double-pointer 'int f(void **p) { return 0; } int main(void) { int *p = 0; return f(&p); }' '1:69: error: incompatible argument type'
check_error typed-missing-pointer-return 'int *f(void) { return; }' '1:16: error: expect return expr'

check typed-conditional-null 1 'int f(int *p) { return p == 0; } int main(void) { return f(1 ? 0 : 1 / 0); }'
check typed-call-pointer-arithmetic 42 'int *f(int *p) { return p; } int main(void) { int x = 42; return *(f(&x) + 0); }'
check_error typed-void-pointer-increment 'int main(void) { void *p = 0; p++; return 0; }' '1:32: error: pointer arithmetic on void pointer'
check_error typed-void-pointer-compound 'int main(void) { void *p = 0; p += 1; return 0; }' '1:33: error: pointer arithmetic on void pointer'
check_error typed-void-pointer-add 'int main(void) { void *p = 0; p + 1; return 0; }' '1:33: error: pointer arithmetic on void pointer'
check_error typed-void-pointer-deref 'int main(void) { void *p = 0; *p; return 0; }' '1:31: error: invalid deref target'
check_error typed-void-compound-value 'void f(void) {} int main(void) { int x = 0; x += f(); return x; }' '1:50: error: void expression used as a value'

# Arguments beyond the sixth use the stack; signatures grow as needed.
check stack-arguments-8 39 'int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8); int main(void) { return f(1, 2, 3, 4, 5, 6, 7, 8); } int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8) { return a1 + 2 * a7 + 3 * a8; }'
check stack-arguments-9 42 'int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9); int main(void) { return f(1, 2, 3, 4, 5, 6, 7, 8, 9); } int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9) { return a1 + 2 * a7 + 3 * a9; }'
check stack-arguments-16 63 'int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15, int a16); int main(void) { return f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16); } int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15, int a16) { return a1 + 2 * a7 + 3 * a16; }'
check stack-arguments-20 75 'int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15, int a16, int a17, int a18, int a19, int a20); int main(void) { return f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20); } int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15, int a16, int a17, int a18, int a19, int a20) { return a1 + 2 * a7 + 3 * a20; }'
check stack-arguments-40 135 'int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15, int a16, int a17, int a18, int a19, int a20, int a21, int a22, int a23, int a24, int a25, int a26, int a27, int a28, int a29, int a30, int a31, int a32, int a33, int a34, int a35, int a36, int a37, int a38, int a39, int a40); int main(void) { return f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40); } int f(int a1, int a2, int a3, int a4, int a5, int a6, int a7, int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15, int a16, int a17, int a18, int a19, int a20, int a21, int a22, int a23, int a24, int a25, int a26, int a27, int a28, int a29, int a30, int a31, int a32, int a33, int a34, int a35, int a36, int a37, int a38, int a39, int a40) { return a1 + 2 * a7 + 3 * a40; }'
check stack-argument-negative 42 'int f(int a, int b, int c, int d, int e, int f, int g) { return -g; } int main(void) { return f(1, 2, 3, 4, 5, 6, -42); }'
check stack-argument-pointer 42 'int *f(int a, int b, int c, int d, int e, int f, int *g) { return g; } int main(void) { int x = 42; return *f(1, 2, 3, 4, 5, 6, &x); }'
check stack-argument-double-pointer 42 'int **f(int a, int b, int c, int d, int e, int f, int g, int **h) { return h; } int main(void) { int x = 42; int *p = &x; return **f(1, 2, 3, 4, 5, 6, 7, &p); }'
check stack-argument-null 1 'int f(int a, int b, int c, int d, int e, int f, int *g) { return g == 0; } int main(void) { return f(1, 2, 3, 4, 5, 6, 0); }'
check stack-argument-address 42 'void set(int *p) { *p = 42; } int f(int a, int b, int c, int d, int e, int f, int g) { set(&g); return g; } int main(void) { return f(1, 2, 3, 4, 5, 6, 7); }'
check stack-argument-recursion 42 'int f(int a, int b, int c, int d, int e, int z, int g) { if (a) return f(a - 1, b, c, d, e, z, g); return g; } int main(void) { return f(4, 2, 3, 4, 5, 6, 42); }'
check stack-argument-cleanup 42 'int f(int a, int b, int c, int d, int e, int f, int g) { return g; } int main(void) { int i; int n = 0; for (i = 0; i < 100; i++) n = f(1, 2, 3, 4, 5, 6, 42); return n; }'
check stack-argument-nested-call 42 'int f(int a, int b, int c, int d, int e, int f, int g) { return a + g; } int main(void) { return f(1, 2, 3, 4, 5, 6, f(7, 8, 9, 10, 11, 12, 34)); }'
check stack-argument-side-effect 42 'int f(int a, int b, int c, int d, int e, int f, int g) { return a + g; } int main(void) { int x = 20; return f(20, 2, 3, 4, 5, 6, (x += 2)); }'
check_error stack-argument-too-few 'int f(int, int, int, int, int, int, int); int main(void) { return f(1,2,3,4,5,6); }' '1:67: error: wrong number of arguments to function '\''f'\'''
check_error stack-argument-too-many 'int f(int, int, int, int, int, int, int); int main(void) { return f(1,2,3,4,5,6,7,8); }' '1:67: error: wrong number of arguments to function '\''f'\'''
check_error stack-argument-type 'int f(int, int, int, int, int, int, int *); int main(void) { return f(1,2,3,4,5,6,42); }' '1:83: error: incompatible argument type'
check_error stack-parameter-conflict 'int f(int, int, int, int, int, int, int); int f(int, int, int, int, int, int, int *);' '1:47: error: conflicting declaration of function '\''f'\'''

# Plain char is a signed byte, promoted to int for arithmetic.
check 'char-local' 42 'int main(void) { char c = 42; return c; }'
check 'char-identity' 1 'char identity(char c) { return c; } int main(void) { char x = 42; char *p = &x; *p = identity(255); return x == -1; }'
check 'char-adjacent-initializers' 42 'int main(void) { char a = 42; char b = 7; return a; }'
check 'char-adjacent-assignment' 42 'int main(void) { char a = 42; char b = 7; b = 8; return a; }'
check 'char-adjacent-indirect-store' 42 'int main(void) { char a = 42; char b = 7; char *p = &b; *p = 8; return a; }'
check 'char-mixed-local-layout' 1 'int main(void) { int x = 42; char a = 7; char b = -1; return x == 42 && a == 7 && b == -1; }'
check 'char-addition-promotion' 254 'int main(void) { char a = 127; char b = 127; return a + b; }'
check 'char-negation-promotion' 128 'int main(void) { char a = -128; return -a; }'
check 'char-bitwise-and-comparison' 1 'int main(void) { char a = -1; return ~a == 0 && a < 0; }'
check 'char-shift-promotion' 1 'int main(void) { char a = -128; char b = 1; return (a >> b) == -64; }'
check 'char-conditional-promotion' 1 'int main(void) { char a = 127; char b = 1; return (1 ? a : b) + 1 == 128; }'
check 'char-mixed-conditional' 1 'int main(void) { char a = -1; return (0 ? 42 : a) == -1; }'
check 'char-assignment-result' 1 'int main(void) { char c = 0; int x = (c = 255); return c == -1 && x == -1; }'
check 'char-compound-narrowing' 1 'int main(void) { char c = 127; return (c += 1) == -128 && c == -128; }'
check 'char-compound-promotion' 1 'int main(void) { char c = 100; return (c *= 3) == 44; }'
check 'char-preincrement-boundary' 1 'int main(void) { char c = 127; return ++c == -128 && c == -128; }'
check 'char-predecrement-boundary' 1 'int main(void) { char c = -128; return --c == 127 && c == 127; }'
check 'char-postincrement-boundary' 1 'int main(void) { char c = 127; int old = c++; return old == 127 && c == -128; }'
check 'char-postdecrement-boundary' 1 'int main(void) { char c = -128; int old = c--; return old == -128 && c == 127; }'
check 'char-adjacent-increments' 42 'int main(void) { char a = 42; char b = 7; char *p = &b; ++*p; (*p)--; return a; }'
check 'char-pointer-byte-stride' 1 'int main(void) { int x = 42; void *v = &x; char *p = v; *(p + 1) = 1; return x == 298; }'
check 'char-pointer-increment' 1 'int main(void) { int x = 42; void *v = &x; char *p = v; char *q = p; p++; return p - q == 1; }'
check 'char-nested-pointer-load' 42 'int main(void) { char x = 42; char *p = &x; char **pp = &p; return **pp; }'
check 'char-parameter-narrowing' 1 'int take(char c) { return c; } int main(void) { return take(255) == -1; }'
check 'char-return-narrowing' 1 'char give(int n) { return n; } int main(void) { return give(255) == -1; }'
check 'char-call-sign-extension' 1 'char give(void) { return -128; } int main(void) { return give() < 0; }'
check 'char-stack-parameters' 1 'char f(char a, char b, char c, char d, char e, char f, char g, char h) { return g + h; } int main(void) { return f(1,2,3,4,5,6,255,128) == 127; }'
check 'char-mixed-parameters' 42 'int f(int a, char b, int *p, char d, int e, char f, char *g, char h) { return a + b + *p + d + e + f + *g + h; } int main(void) { int x = 10; char y = 10; return f(1,2,&x,3,4,5,&y,7); }'
check 'char-default-argument-promotion' 42 'int f(); int main(void) { char c = 42; return f(c); } int f(int n) { return n; }'
check 'char-for-declaration' 1 'int main(void) { int total = 0; for (char c = 0; c < 10; c++) total += c; return total == 45; }'
check 'char-switch' 42 'int main(void) { char c = 255; switch (c) { case -1: return 42; default: return 0; } }'
check 'char-logical-operators' 1 'int main(void) { char c = -1; return !c == 0 && (c || 0) && (c && 1); }'
check 'char-chained-assignment' 1 'int main(void) { char c = 0; return (c = (c = 255)) == -1; }'
check 'char-initializer-boundary-127' 1 'int main(void) { char c = 127; return c == 127; }'
check 'char-initializer-boundary-128' 1 'int main(void) { char c = 128; return c == -128; }'
check 'char-initializer-boundary-255' 1 'int main(void) { char c = 255; return c == -1; }'
check 'char-initializer-boundary-256' 1 'int main(void) { char c = 256; return c == 0; }'
check 'char-initializer-boundary--129' 1 'int main(void) { char c = -129; return c == 127; }'
check 'char-initializer-boundary--128' 1 'int main(void) { char c = -128; return c == -128; }'
check 'char-initializer-boundary--256' 1 'int main(void) { char c = -256; return c == 0; }'
check 'char-compound-+=' 1 'int main(void) { char c = 127; c += 1; return c == -128; }'
check 'char-compound--=' 1 'int main(void) { char c = -128; c -= 1; return c == 127; }'
check 'char-compound-*=' 1 'int main(void) { char c = 100; c *= 3; return c == 44; }'
check 'char-compound-/=' 1 'int main(void) { char c = -127; c /= 2; return c == -63; }'
check 'char-compound-%=' 1 'int main(void) { char c = -127; c %= 2; return c == -1; }'
check 'char-compound-<<=' 1 'int main(void) { char c = 64; c <<= 1; return c == -128; }'
check 'char-compound->>=' 1 'int main(void) { char c = -128; c >>= 1; return c == -64; }'
check 'char-compound-&=' 1 'int main(void) { char c = -1; c &= 127; return c == 127; }'
check 'char-compound-^=' 1 'int main(void) { char c = 127; c ^= 255; return c == -128; }'
check 'char-compound-|=' 1 'int main(void) { char c = 0; c |= 255; return c == -1; }'
check_error char-conflicting-parameter 'int f(char); int f(int);' '1:18: error: conflicting declaration of function '\''f'\'''
check_error char-conflicting-return 'char f(void); int f(void);' '1:19: error: conflicting declaration of function '\''f'\'''
check_error char-prototype-default-promotion 'int f(); int f(char);' '1:14: error: conflicting declaration of function '\''f'\'''
check_error char-prototype-default-promotion-reverse 'int f(char); int f();' '1:18: error: conflicting declaration of function '\''f'\'''
check_error char-incompatible-pointer 'int main(void) { char *p; int *q = p; return 0; }' '1:32: error: incompatible initializer type'
check_error char-not-null-pointer-constant 'int main(void) { char c = 0; int *p = c; return 0; }' '1:35: error: incompatible initializer type'
check_error char-pointer-assignment 'int main(void) { char c; int *p = 0; c = p; return 0; }' '1:40: error: incompatible assignment type'

# Ordinary character constants are int tokens; byte escapes follow signed char.
check character-literal-letter 65 "int main(void) { return 'A'; }"
check character-literal-digit 48 "int main(void) { return '0'; }"
check character-literal-space 32 "int main(void) { return ' '; }"
check character-literal-double-quote 34 "int main(void) { return '\"'; }"
check character-literal-escaped-quote 39 "int main(void) { return '\\''; }"
check character-literal-escaped-double-quote 34 "int main(void) { return '\\\"'; }"
check character-literal-backslash 92 "int main(void) { return '\\\\'; }"
check character-literal-question 63 "int main(void) { return '\\?'; }"
check character-literal-alert 7 "int main(void) { return '\\a'; }"
check character-literal-backspace 8 "int main(void) { return '\\b'; }"
check character-literal-form-feed 12 "int main(void) { return '\\f'; }"
check character-literal-newline 10 "int main(void) { return '\\n'; }"
check character-literal-carriage-return 13 "int main(void) { return '\\r'; }"
check character-literal-tab 9 "int main(void) { return '\\t'; }"
check character-literal-vertical-tab 11 "int main(void) { return '\\v'; }"
check character-literal-null 0 "int main(void) { return '\\0'; }"
check character-literal-octal-one-digit 7 "int main(void) { return '\\7'; }"
check character-literal-octal-two-digits 10 "int main(void) { return '\\12'; }"
check character-literal-octal-three-digits 65 "int main(void) { return '\\101'; }"
check character-literal-hex 65 "int main(void) { return '\\x41'; }"
check character-literal-hex-leading-zeroes 65 "int main(void) { return '\\x00000041'; }"
check character-literal-signed-byte 1 "int main(void) { return '\\xff' == -1 && '\\377' == -1 && '\\x80' == -128 && '\\200' == -128; }"
check character-literal-char-initialization 1 "int main(void) { char c = 'A'; return c == 65 && 'A' + 200 == 265; }"
check character-literal-switch 42 "int main(void) { switch ('\\n') { case 10: return 42; default: return 0; } }"
check character-literal-case 42 "int main(void) { switch (10) { case '\\n': return 42; default: return 0; } }"
check character-literal-comment-characters 89 "int main(void) { return '/' + '*'; }"
check character-literal-function-argument 1 "char identity(char c) { return c; } int main(void) { return identity('\\xff') == -1; }"
check_error character-literal-empty "int main(void) { return ''; }" "1:25: error: empty character literal"
check_error character-literal-multiple "int main(void) { return 'ab'; }" "1:25: error: multi-character literals not supported"
check_error character-literal-invalid-escape "int main(void) { return '\\q'; }" "1:25: error: invalid escape sequence in character literal"
check_error character-literal-empty-hex "int main(void) { return '\\x'; }" "1:25: error: expect hexadecimal digit in character escape"
check_error character-literal-invalid-hex "int main(void) { return '\\xg'; }" "1:25: error: expect hexadecimal digit in character escape"
check_error character-literal-octal-overflow "int main(void) { return '\\400'; }" "1:25: error: character escape out of range"
check_error character-literal-hex-overflow "int main(void) { return '\\x100'; }" "1:25: error: character escape out of range"
check_error character-literal-long-hex-overflow "int main(void) { return '\\xffffffffffffffffffff'; }" "1:25: error: character escape out of range"
check_error character-literal-octal-limit "int main(void) { return '\\1234'; }" "1:25: error: multi-character literals not supported"
check_error character-literal-eof "int main(void) { return '" "1:25: error: unterminated character literal"
check_error character-literal-missing-quote "int main(void) { return 'a; }" "1:25: error: unterminated character literal"
check_error character-literal-escape-eof "int main(void) { return '\\" "1:25: error: unterminated character literal"
check_error character-literal-raw-newline $'int main(void) { return \'\n\'; }' "1:25: error: unterminated character literal"
check_error character-literal-raw-crlf $'int main(void) { return \'\r\n\'; }' "1:25: error: unterminated character literal"
check_error character-literal-escaped-newline $'int main(void) { return \'\\\n\'; }' "1:25: error: unterminated character literal"

# String literal lexer diagnostics.
check_error string-unterminated 'int main(void) { return "hello; }' '1:25: error: unterminated string literal'
check_error string-missing-closing-quote 'int main(void) { return "; }' '1:25: error: unterminated string literal'
check_error string-trailing-backslash 'int main(void) { return "hello\; }' '1:25: error: unterminated string literal'
check_error string-raw-newline $'int main(void) { return "hello\nworld"; }' '1:25: error: unterminated string literal'
check_error string-raw-crlf $'int main(void) { return "hello\r\nworld"; }' '1:25: error: unterminated string literal'
check_error string-escaped-newline $'int main(void) { return "hello\\\nworld"; }' '1:25: error: unterminated string literal'
check_error string-invalid-escape 'int main(void) { return "\q"; }' '1:25: error: invalid escape sequence in string literal'
check_error string-invalid-octal-escape 'int main(void) { return "\8"; }' '1:25: error: invalid escape sequence in string literal'
check_error string-empty-hex-escape 'int main(void) { return "\x"; }' '1:25: error: expect hexadecimal digit in character escape'
check_error string-invalid-hex-escape 'int main(void) { return "\xg"; }' '1:25: error: expect hexadecimal digit in character escape'
check_error string-octal-escape-overflow 'int main(void) { return "\400"; }' '1:25: error: character escape out of range'
check_error string-hex-escape-overflow 'int main(void) { return "\x100"; }' '1:25: error: character escape out of range'
check_error string-long-hex-escape-overflow 'int main(void) { return "\xffffffffffffffffffff"; }' '1:25: error: character escape out of range'

# String literal types and invalid expression contexts.
check_error string-integer-initializer 'int main(void) { int x = "abc"; return 0; }' '1:22: error: incompatible initializer type'
check_error string-pointer-initializer-type 'int main(void) { int *p = "abc"; return 0; }' '1:23: error: incompatible initializer type'
check_error string-integer-argument 'int f(int); int main(void) { return f("abc"); }' '1:39: error: incompatible argument type'
check_error string-assignment-target 'int main(void) { "a" = "b"; return 0; }' '1:22: error: invalid assignment target'
check_error string-increment-target 'int main(void) { ++"abc"; return 0; }' '1:18: error: invalid increment target'
check_error string-address-pointer-type 'int main(void) { char *p = &"abc"; return 0; }' '1:24: error: incompatible initializer type'
check_error string-invalid-addition 'int main(void) { "a" + "b"; return 0; }' '1:22: error: invalid operands to binary +'
check_error string-switch-condition 'int main(void) { switch ("abc") { default: return 0; } }' '1:26: error: switch condition must have integer type'
check_error string-case-label 'int main(void) { switch (0) { case "a": return 0; } return 1; }' '1:36: error: case label must have integer type'
check_error string-array-bound 'int main(void) { char a["abc"]; return 0; }' '1:25: error: array bound must have integer type'
check_error string-parenthesized-concat 'int main(void) { ("a") "b"; return 0; }' '1:23: error: expect '\'';'\'''

# Fixed-size array declarations and array parameter adjustment.
for spec in 'char' 'unsigned char' 'short' 'unsigned short' 'int' 'unsigned' \
    'long' 'unsigned long' 'long long' 'unsigned long long'; do
    check "array-declaration-$spec" 42 "int main(void) { $spec a[3]; return 42; }"
done
check array-pointer-elements 42 'int main(void) { int *a[3]; void *b[2]; int **c[1]; return 42; }'
check array-constant-bounds 42 'int main(void) { int a[1 + 2 * 3]; char b[1 ? 5 : 2]; short c[1U << 3]; return 42; }'
check array-scope-and-following-local 42 'int main(void) { int a[3]; { char a[5]; } int x = 42; return x; }'
check array-for-declaration 42 'int main(void) { for (int a[3]; 0;) ; return 42; }'
check array-parameter-definition 42 'int f(int a[1]) { return *a; } int main(void) { int x = 42; return f(&x); }'
check array-unnamed-parameter 42 'int f(int [3]); int f(int *p) { return *p; } int main(void) { int x = 42; return f(&x); }'
check array-parameter-compatible-bounds 42 'int f(int a[2]); int f(int a[7]); int f(int *a) { return *a; } int main(void) { int x = 42; return f(&x); }'
check array-pointer-parameter 42 'int *f(int *a[1]) { return *a; } int main(void) { int x = 42; int *p = &x; return *f(&p); }'
check array-char-parameter 42 'int f(char a[1]) { *a = 42; return *a; } int main(void) { char x; return f(&x); }'

check_error array-zero-bound 'int main(void) { int a[0]; return 0; }' '1:24: error: array bound must be positive'
check_error array-negative-bound 'int main(void) { int a[-1]; return 0; }' '1:24: error: array bound must be positive'
check_error array-missing-bound 'int main(void) { int a[]; return 0; }' '1:22: error: variable has incomplete type'
check_error array-variable-bound 'int main(void) { int n = 3; int a[n]; return 0; }' '1:36: error: not an integer constant expression'
check_error array-call-bound 'int f(void); int main(void) { int a[f()]; return 0; }' '1:40: error: not an integer constant expression'
check_error array-pointer-bound 'int main(void) { int n; int a[&n]; return 0; }' '1:31: error: array bound must have integer type'
check_error array-void-element 'int main(void) { void a[3]; return 0; }' '1:24: error: array element has void type'
check_error array-missing-rbracket 'int main(void) { int a[3; return 0; }' '1:25: error: expect '\'']'\'''
check_error array-large-bound 'int main(void) { int a[536870912]; return 0; }' '1:24: error: array size exceeds supported limit'
check_error array-unsigned-large-bound 'int main(void) { char a[18446744073709551615ULL]; return 0; }' '1:25: error: array size exceeds supported limit'
check_error array-stack-overflow 'int main(void) { char a[2147483647]; return 0; }' '1:23: error: local variables exceed supported stack size'
check_error array-total-stack-overflow 'int main(void) { char a[2147483620]; int b[10]; return 0; }' '1:42: error: local variables exceed supported stack size'
check_error array-multidimensional 'int main(void) { int a[2][3]; return 0; }' '1:26: error: multidimensional arrays are not supported yet'
check_error array-initializer 'int main(void) { int a[2] = {1, 2}; return 0; }' '1:27: error: array initializers are not supported yet'
check_error array-function-return 'int f[3](void);' '1:5: error: function cannot return an array'
check_error array-parameter-conflict 'int f(int a[3]); int f(char *a);' '1:22: error: conflicting declaration of function '\''f'\'''

# Struct declarations, layout, and the tag namespace.
check struct-local-declaration 42 'struct S { int x; }; int main(void) { struct S s; return 42; }'
check struct-forward-definition 42 'struct S; struct S { int x; }; struct S; int main(void) { return 42; }'
check struct-self-pointer 42 'struct Node { int value; struct Node *next; }; int main(void) { struct Node n; struct Node *p = &n; return p == &n ? 42 : 0; }'
check struct-mutual-pointers 42 'struct A; struct B { struct A *a; }; struct A { struct B *b; }; int main(void) { struct A a; struct B b; return 42; }'
check struct-anonymous 42 'int main(void) { struct { int x; char y; } s; return 42; }'
check struct-multiple-members 42 'int main(void) { struct S { int x, y; char *p, bytes[3]; }; struct S s; return 42; }'
check struct-nested-members 42 'struct S { struct { int x; } inner; long a[2]; }; int main(void) { struct S s; return 42; }'
check struct-separate-namespace 42 'struct S { int x; }; int main(void) { int S = 42; struct S s; return S; }'
check struct-padding-and-alignment 16 'struct S { char c; long n; }; int main(void) { struct S a[2]; void *v = a; char *p = v; v = a + 1; char *q = v; return q - p; }'
check struct-tail-padding 16 'struct S { long n; char c; }; int main(void) { struct S a[2]; void *v = a; char *p = v; v = a + 1; char *q = v; return q - p; }'
check struct-nested-layout 24 'struct Inner { int x; char c; }; struct S { char c; struct Inner inner; long n; }; int main(void) { struct S a[2]; void *v = a; char *p = v; v = a + 1; char *q = v; return q - p; }'
check struct-pointer-function 42 'struct S { int x; }; struct S *id(struct S *p) { return p; } int main(void) { struct S s; return id(&s) == &s ? 42 : 0; }'
check struct-incomplete-pointer-parameter 42 'struct S; int f(struct S *p) { return p == 0 ? 42 : 0; } int main(void) { return f(0); }'
check struct-tag-shadowing 42 'struct S { int x; }; int main(void) { struct S s; struct S *p = &s; { struct S { char c; }; struct S t; } struct S *q = &s; return p == q ? 42 : 0; }'
check struct-sibling-scopes 42 'int main(void) { { struct S { int x; }; } { struct S { char c; }; } return 42; }'
check struct-for-scope 42 'int main(void) { for (struct S { int x; } *p = 0; p; ) {} struct S { char c; }; return 42; }'
check struct-parameter-tag-scope 42 'int f(struct S { int x; } *p) { struct S s; return p == 0 ? 42 : 0; } int main(void) { struct S { char c; }; return f(0); }'

check_error struct-redefinition 'struct S { int x; }; struct S { int y; };' '1:29: error: redefinition of struct '\''S'\'''
check_error struct-recursive-definition 'struct S { struct S { int x; } member; };' '1:19: error: redefinition of struct '\''S'\'''
check_error struct-empty 'struct S {};' '1:11: error: empty structs are not supported'
check_error struct-duplicate-member 'struct S { int x; char x; };' '1:24: error: duplicate struct member'
check_error struct-void-member 'struct S { void x; };' '1:17: error: member has void type'
check_error struct-incomplete-member 'struct S { struct Missing x; };' '1:27: error: member has incomplete type'
check_error struct-self-value-member 'struct S { struct S next; };' '1:21: error: member has incomplete type'
check_error struct-incomplete-array-member 'struct S { struct Missing x[2]; };' '1:28: error: array element has incomplete type'
check_error struct-missing-member-name 'struct S { int; };' '1:15: error: expect member name'
check_error struct-missing-member-semicolon 'struct S { int x };' '1:17: error: expect '\'';'\'''
check_error struct-missing-brace 'struct S { int x;' '1:18: error: expect '\''}'\'''
check_error struct-missing-tag-or-body 'struct;' '1:7: error: expect struct tag or '\''{'\'''
check_error struct-bit-field 'struct S { int x:3; };' '1:17: error: expect '\'';'\'''
check_error struct-flexible-array 'struct S { int x; char data[]; };' '1:24: error: member has incomplete type'
check_error struct-member-initializer 'struct S { int x = 1; };' '1:17: error: expect '\'';'\'''
check_error struct-incomplete-local 'int main(void) { struct S s; return 0; }' '1:27: error: variable has incomplete type'
check_error struct-incomplete-array 'int main(void) { struct S a[2]; return 0; }' '1:28: error: array element has incomplete type'
check_error struct-array-overflow 'struct S { long x[268435455]; long y[2]; };' '1:36: error: struct size exceeds supported limit'
check_error struct-tail-padding-overflow 'struct S { long x; char a[2147483639]; };' '1:1: error: struct size exceeds supported limit'
check_error struct-initializer 'struct S { int x; }; int main(void) { struct S s = 0; return 0; }' '1:50: error: struct initializers are not supported yet'
check_error struct-return-by-value 'struct S { int x; }; struct S f(void);' '1:31: error: returning structs by value is not supported yet'
check_error struct-parameter-by-value 'struct S { int x; }; int f(struct S s);' '1:37: error: passing structs by value is not supported yet'
check_error struct-pointer-type-mismatch 'struct A { int x; }; struct B { int x; }; int main(void) { struct A *a; struct B *b = a; return 0; }' '1:83: error: incompatible initializer type'
check_error struct-anonymous-type-identity 'int main(void) { struct { int x; } a; struct { int x; } *p = &a; return 0; }' '1:58: error: incompatible initializer type'
check_error struct-local-tag-outside-block 'int main(void) { { struct S { int x; }; } struct S s; return 0; }' '1:52: error: variable has incomplete type'
check_error struct-function-tag-scope 'int f(void) { struct S { int x; }; return 0; } int main(void) { struct S s; return 0; }' '1:74: error: variable has incomplete type'
check_error struct-forward-shadow 'struct S { int x; }; int main(void) { struct S; struct S s; return 0; }' '1:58: error: variable has incomplete type'
check_error struct-prototype-tag-scope 'int f(struct S *p); struct S { int x; }; int f(struct S *p);' '1:46: error: conflicting declaration of function '\''f'\'''
check_error struct-incomplete-pointer-add 'int main(void) { struct S *p; p + 1; return 0; }' '1:33: error: pointer arithmetic on incomplete type'
check_error struct-incomplete-pointer-increment 'int main(void) { struct S *p; p++; return 0; }' '1:32: error: pointer arithmetic on incomplete type'
check_error struct-incomplete-pointer-compound 'int main(void) { struct S *p; p += 1; return 0; }' '1:33: error: pointer arithmetic on incomplete type'
check_error struct-assignment-by-value 'struct S { int x; }; int main(void) { struct S a; struct S b; a = b; return 0; }' '1:67: error: struct values are not supported yet'
check_error struct-unprototyped-call 'int f(); struct S { int x; }; int main(void) { struct S a; return f(a); }' '1:69: error: passing structs by value is not supported yet'
check_error struct-condition 'struct S { int x; }; int main(void) { struct S a; if (a) return 1; return 0; }' '1:55: error: struct values are not supported yet'
check_error struct-prefix-increment 'struct S { int x; }; int main(void) { struct S a; ++a; return 0; }' '1:51: error: invalid increment target'
check_error struct-comparison 'struct S { int x; }; int main(void) { struct S a; return a == a; }' '1:58: error: struct values are not supported yet'

# Struct member addresses reuse scalar loads, stores, and pointer arithmetic.
for spec in 'char' 'unsigned char' 'short' 'unsigned short' 'int' 'unsigned' 'long' 'unsigned long' 'long long' 'unsigned long long'; do
    check "member-load-store-$spec" 42 "struct S { char before; $spec value; char after; }; int main(void) { struct S s; struct S *p = &s; s.before = 7; s.after = 9; s.value = 20; p->value = p->value + 22; return s.before == 7 && s.after == 9 ? s.value : 0; }"
done
check member-dot-and-arrow 42 'struct Point { int x; int y; }; int main(void) { struct Point p; struct Point *ptr = &p; p.x = 20; ptr->y = 22; return p.x + p.y; }'
check member-narrow-and-signed-values 1 'struct S { char a; unsigned char b; short c; unsigned short d; int e; unsigned f; }; int main(void) { struct S s; s.a = 255; s.b = 511; s.c = 65535; s.d = 131071; s.e = -1; s.f = 4294967295U; return s.a == -1 && s.b == 255 && s.c == -1 && s.d == 65535 && s.e < 0 && s.f > 0; }'
check member-wide-values 1 'struct S { long x; unsigned long y; long long z; unsigned long long w; }; int main(void) { struct S s; s.x = -4294967296L; s.y = 18446744073709551615UL; s.z = 1LL << 40; s.w = 1ULL << 63; return s.x < 0 && s.y >> 63 == 1 && s.z >> 40 == 1 && s.w >> 63 == 1; }'
check member-nested-struct 42 'struct I { char c; int x; }; struct O { char c; struct I inner; }; int main(void) { struct O o; struct O *p = &o; o.c = 1; p->inner.c = 2; o.inner.x = 39; return o.c + o.inner.c + p->inner.x; }'
check member-arrow-chain 42 'struct I { int x; }; struct O { char c; struct I *inner; }; int main(void) { struct I i; struct O o; struct O *p = &o; p->inner = &i; p->inner->x = 42; return o.inner->x; }'
check member-linked-list 42 'struct Node { int value; struct Node *next; }; int main(void) { struct Node a; struct Node b; a.value = 20; b.value = 22; a.next = &b; b.next = 0; struct Node *p = &a; int sum = 0; while (p) { sum += p->value; p = p->next; } return sum; }'
check member-array-elements 42 'struct S { char c; int values[3]; }; int main(void) { struct S s; struct S *p = &s; s.values[0] = 7; p->values[1] = 11; s.values[2] = 24; return s.values[0] + p->values[1] + s.values[2]; }'
check member-array-of-struct 42 'struct S { int x; }; struct O { char c; struct S items[2]; }; int main(void) { struct O o; o.items[0].x = 7; o.items[1].x = 35; return o.items[0].x + o.items[1].x; }'
check member-struct-array-base 42 'struct S { int x; }; int main(void) { struct S a[2]; a[0].x = 20; a[1].x = 22; struct S *p = a; return p->x + (p + 1)->x; }'
check member-address-of-scalar 42 'struct S { char c; int x; }; int main(void) { struct S s; int *p = &s.x; *p = 42; return (&s)->x; }'
check member-address-of-struct 42 'struct I { int x; }; struct O { char c; struct I inner; }; int main(void) { struct O o; struct I *p = &o.inner; p->x = 42; return o.inner.x; }'
check member-array-decay-and-address 42 'struct S { int values[2]; }; int main(void) { struct S s; int *p = s.values; p[1] = 42; return (*(&s.values))[1]; }'
check member-layout-offsets 1 'struct S { char c; int x; short y; }; int main(void) { struct S s; void *v = &s; char *base = v; v = &s.x; char *x = v; v = &s.y; char *y = v; return x - base == 4 && y - base == 8; }'
check member-nested-layout-offsets 1 'struct I { char c; long n; }; struct O { char c; struct I inner; char end; }; int main(void) { struct O o; void *v = &o; char *base = v; v = &o.inner.n; char *n = v; v = &o.end; char *end = v; return n - base == 16 && end - base == 24; }'
check member-increment-decrement 1 'struct S { char c; unsigned char u; short s; unsigned short t; int i; unsigned j; long l; unsigned long long q; }; int main(void) { struct S x; x.c = 126; x.u = 254; x.s = 100; x.t = 65534; x.i = 40; x.j = 40; x.l = 1L << 40; x.q = 1ULL << 63; return x.c++ == 126 && ++x.c == -128 && x.u++ == 254 && ++x.u == 0 && --x.s == 99 && x.t-- == 65534 && x.i++ == 40 && ++x.j == 41 && x.l++ == 1L << 40 && x.q-- == 1ULL << 63; }'
check member-pointer-increment 42 'struct S { int x; int *p; }; int main(void) { struct S s; int a[2]; a[1] = 42; s.p = a; s.p++; return *s.p; }'
check member-assignment-result 1 'struct S { char x; }; int main(void) { struct S s; return (s.x = 255) == -1 && s.x == -1; }'
check member-chained-assignment 1 'struct S { int x; }; int main(void) { struct S s; struct S t; s.x = t.x = 42; return s.x == 42 && t.x == 42; }'
check member-index-evaluated-once 1 'struct S { int x; }; int main(void) { struct S a[2]; int i = 0; a[i++].x = 41; i = 0; int old = a[i++].x++; return old == 41 && i == 1 && a[0].x == 42; }'
check member-call-base-evaluated-once 1 'struct S { int x; }; struct S *get(struct S *p, int *n) { (*n)++; return p; } int main(void) { struct S s; int n = 0; get(&s, &n)->x = 41; int old = get(&s, &n)->x++; return n == 2 && old == 41 && s.x == 42; }'
check member-call-base-and-rhs 42 'struct S { char c; int x; }; int value(void) { return 42; } struct S *get(struct S *p) { return p; } int main(void) { struct S s; get(&s)->x = value(); return s.x; }'
check member-pointer-parameter 42 'struct S { int x; }; int read(struct S *p) { return p->x; } int main(void) { struct S s; s.x = 42; return read(&s); }'
check member-stack-call-argument 42 'struct S { int x; }; int last(int a, int b, int c, int d, int e, int f, int g) { return g; } int main(void) { struct S s; s.x = 42; return last(s.x, s.x, s.x, s.x, s.x, s.x, s.x); }'
check member-string-pointer 42 'struct S { char *text; }; int main(void) { struct S s; s.text = "*"; return s.text[0]; }'
check member-anonymous-struct 42 'int main(void) { struct { int x; } s; s.x = 42; return s.x; }'
check member-conditional-pointer 42 'struct S { int x; }; int main(void) { struct S s; struct S t; s.x = 7; t.x = 42; int choose = 0; return (choose ? &s : &t)->x; }'
check member-discarded-scalar 42 'struct S { int x; }; int main(void) { struct S s; s.x = 42; s.x; return (*(&s)).x; }'

# Struct member access syntax and operand checks.
check_error member-dot-integer 'int main(void) { int x; return x.y; }' '1:33: error: '\''.'\'' requires a struct operand'
check_error member-dot-pointer 'struct S { int x; }; int main(void) { struct S *p; return p.x; }' '1:60: error: '\''.'\'' requires a struct operand'
check_error member-dot-array 'struct S { int x; }; int main(void) { struct S a[2]; return a.x; }' '1:62: error: '\''.'\'' requires a struct operand'
check_error member-arrow-integer 'int main(void) { int x; return x->y; }' '1:33: error: '\''->'\'' requires a pointer to struct'
check_error member-arrow-integer-pointer 'int main(void) { int *p; return p->x; }' '1:34: error: '\''->'\'' requires a pointer to struct'
check_error member-arrow-void-pointer 'int main(void) { void *p; return p->x; }' '1:35: error: '\''->'\'' requires a pointer to struct'
check_error member-arrow-struct 'struct S { int x; }; int main(void) { struct S s; return s->x; }' '1:58: error: struct values are not supported yet'
check_error member-arrow-pointer-to-pointer 'struct S { int x; }; int main(void) { struct S **p; return p->x; }' '1:61: error: '\''->'\'' requires a pointer to struct'
check_error member-incomplete-struct 'int main(void) { struct S *p; return p->x; }' '1:39: error: member access on incomplete struct'
check_error member-missing-dot 'struct S { int x; }; int main(void) { struct S s; return s.y; }' '1:60: error: no member named '\''y'\'' in struct'
check_error member-missing-arrow 'struct S { int x; }; int main(void) { struct S *p; return p->y; }' '1:62: error: no member named '\''y'\'' in struct'
check_error member-name-after-dot 'struct S { int x; }; int main(void) { struct S s; return s.; }' '1:60: error: expect member name'
check_error member-name-after-arrow 'struct S { int x; }; int main(void) { struct S *p; return p->; }' '1:62: error: expect member name'
check_error member-keyword-name 'struct S { int x; }; int main(void) { struct S s; return s.int; }' '1:60: error: expect member name'
check_error member-scalar-chain 'struct S { int x; }; int main(void) { struct S s; return s.x.y; }' '1:61: error: '\''.'\'' requires a struct operand'
check_error member-array-assignment 'struct S { int a[2]; }; int main(void) { struct S s; s.a = 0; return 0; }' '1:58: error: invalid assignment target'
check_error member-array-increment 'struct S { int a[2]; }; int main(void) { struct S s; s.a++; return 0; }' '1:57: error: invalid increment target'
check_error member-struct-increment 'struct T { int x; }; struct S { struct T t; }; int main(void) { struct S s; ++s.t; return 0; }' '1:77: error: invalid increment target'
check_error member-pointer-type 'struct S { char *p; }; int main(void) { struct S s; int *p = s.p; return 0; }' '1:58: error: incompatible initializer type'
check_error member-array-address-type 'struct S { int a[2]; }; int main(void) { struct S s; int *p = &s.a; return 0; }' '1:59: error: incompatible initializer type'
check member-compound-assignment 42 'struct S { int x; }; int main(void) { struct S s; s.x = 40; s.x += 2; return s.x; }'
check_error member-address-rvalue 'struct S { int x; }; int main(void) { struct S s; int *p = &(s.x + 1); return 0; }' '1:60: error: invalid address-of target'

# String literals have static storage and decay to pointers in value contexts.
check string-first-byte 97 'int main(void) { return "abc"[0]; }'
check string-reversed-subscript 99 'int main(void) { return 2["abc"]; }'
check string-final-terminator 0 'int main(void) { return "abc"[3]; }'
check string-empty 0 'int main(void) { return ""[0]; }'
check string-embedded-zero 1 'int main(void) { char *p = "a\0b"; return p[0] == 97 && p[1] == 0 && p[2] == 98 && p[3] == 0; }'
check string-simple-escapes 1 'int main(void) { char *p = "\n\t\r\a\b\f\v"; return p[0] == 10 && p[1] == 9 && p[2] == 13 && p[3] == 7 && p[4] == 8 && p[5] == 12 && p[6] == 11 && p[7] == 0; }'
check string-escaped-punctuation 1 'int main(void) { char *p = "\"\\\?"; return p[0] == 34 && p[1] == 92 && p[2] == 63 && p[3] == 0; }'
check string-numeric-escapes 1 'int main(void) { char *p = "\101\x42\377\x80"; return p[0] == 65 && p[1] == 66 && p[2] == -1 && p[3] == -128 && p[4] == 0; }'
check string-concatenation 1 'int main(void) { char *p = "ab" /* concatenate */ "cd"; return p[0] == 97 && p[2] == 99 && p[3] == 100 && p[4] == 0; }'
check string-concatenated-zero 1 'int main(void) { char *p = "a\0" "b"; return p[0] == 97 && p[1] == 0 && p[2] == 98 && p[3] == 0; }'
check string-concatenated-escape-boundary 1 'int main(void) { char *p = "\x4" "1"; return p[0] == 4 && p[1] == 49 && p[2] == 0; }'
check string-concatenated-empty 1 'int main(void) { char *p = "" "" "a" ""; return p[0] == 97 && p[1] == 0; }'
check string-multiple-byte-directives 1 'int main(void) { char *p = "0123456789abcdefXYZ"; return p[15] == 102 && p[16] == 88 && p[18] == 90 && p[19] == 0; }'
check string-pointer-assignment 98 'int main(void) { char *p; p = "abc"; return *(p + 1); }'
check string-address-of-array 98 'int main(void) { return (*(&"abc"))[1]; }'
check string-pointer-to-array-arithmetic 99 'int main(void) { return (*(&"abc" + 1 - 1))[2]; }'
check string-call-argument 98 'int byte(char *p) { return p[1]; } int main(void) { return byte("abc"); }'
check string-stack-argument 98 'int byte(int a, int b, int c, int d, int e, int f, char *p) { return p[1]; } int main(void) { return byte(0,0,0,0,0,0,"abc"); }'
check string-static-lifetime 1 'char *text(void) { return "abc"; } int main(void) { char *p = text(); int i = 0; while (i++ < 3) { if (text() != p) return 0; } return p[2] == 99; }'
check string-labels-across-functions 1 'char *first(void) { return "abc"; } char *second(void) { return "xyz"; } int main(void) { return first()[0] == 97 && second()[0] == 120; }'
check string-pointer-array 98 'int main(void) { char *p[2]; p[0] = "abc"; p[1] = "xyz"; return p[0][1]; }'
check string-conditional 120 'int main(void) { return (0 ? "abc" : "xyz")[0]; }'
check string-conditions 1 'int main(void) { if ("") return !!"abc" && ("x" || 0) && ("y" && 1); return 0; }'
check string-discarded-expression 98 'int main(void) { "discarded"; return (0, "abc")[1]; }'
check string-libc-call 1 'int strcmp(char *a, char *b); int main(void) { return strcmp("hello", "hel" "lo") == 0 && strcmp("a", "b") < 0; }'

# Array expressions, element access, and pointer conversion.
for spec in 'char' 'unsigned char' 'short' 'unsigned short' 'int' 'unsigned' 'long' 'unsigned long' 'long long' 'unsigned long long'; do
    check "array-elements-$spec" 42 "int main(void) { $spec a[3]; a[0] = 7; a[1] = 11; a[2] = 24; return a[0] + a[1] + a[2]; }"
done
check array-signed-char 1 'int main(void) { char a[2]; a[0] = 255; a[1] = 42; return a[0] == -1 && a[1] == 42; }'
check array-unsigned-char 1 'int main(void) { unsigned char a[2]; a[0] = 511; a[1] = 42; return a[0] == 255 && a[1] == 42; }'
check array-signed-short 1 'int main(void) { short a[2]; a[0] = 65535; a[1] = 42; return a[0] == -1 && a[1] == 42; }'
check array-unsigned-short 1 'int main(void) { unsigned short a[2]; a[0] = 131071; a[1] = 42; return a[0] == 65535 && a[1] == 42; }'
check array-wide-values 1 'int main(void) { long long a[2]; a[0] = 1LL << 40; a[1] = -1; return a[0] >> 40 == 1 && a[1] < 0; }'
check array-unsigned-wide-values 1 'int main(void) { unsigned long long a[2]; a[0] = 18446744073709551615ULL; a[1] = 1ULL << 63; return a[0] / 2 == 9223372036854775807LL && a[1] >> 63 == 1; }'
check array-pointer-initializer 42 'int main(void) { int a[3]; int *p = a; *(p + 2) = 42; return a[2]; }'
check array-pointer-assignment 42 'int main(void) { int a[3]; int *p; p = a; p[1] = 42; return *(a + 1); }'
check array-reversed-subscript 42 'int main(void) { int a[3]; 2[a] = 42; return a[2]; }'
check array-negative-index 42 'int main(void) { int a[3]; a[0] = 42; int *p = a + 2; long n = -2; return p[n]; }'
check array-unsigned-index 42 'int main(void) { int a[3]; unsigned long n = 2; a[n] = 42; return a[2U]; }'
check array-pointer-scaling 1 'int main(void) { int a[3]; return a + 3 - a == 3 && (&a + 1) - &a == 1; }'
check array-address-preserves-type 42 'int main(void) { int a[3]; (&a)[0][2] = 42; return (*(&a))[2]; }'
check array-element-address 42 'int main(void) { int a[2]; int *p = &a[1]; *p = 42; return a[1]; }'
check array-parenthesized-address 42 'int main(void) { int a[2]; int *p = (a); p[0] = 42; return (*(&(a)))[0]; }'
check array-element-increment 1 'int main(void) { int a[2]; a[0] = 40; a[1] = 42; return a[0]++ == 40 && ++a[0] == 42 && a[1]-- == 42 && --a[1] == 40; }'
check array-index-evaluated-once 1 'int main(void) { int a[2]; int i = 0; a[i++] = 41; i = 0; return a[i++]++ == 41 && i == 1 && a[0] == 42; }'
check array-base-evaluated-once 42 'int *base(int *p, int *n) { (*n)++; return p; } int main(void) { int a[2]; int n = 0; base(a, &n)[1] = 42; return n == 1 ? a[1] : 0; }'
check array-comma-index 42 'int main(void) { int a[2]; a[0] = 7; a[1] = 42; int i = 0; return a[(i = 1, i)]; }'
check array-call-argument 42 'int sum(int a[3]) { return a[0] + a[1] + a[2]; } int main(void) { int a[3]; a[0] = 7; a[1] = 11; a[2] = 24; return sum(a); }'
check array-default-argument-conversion 42 'int f(); int main(void) { int a[1]; a[0] = 42; return f(a); } int f(int *p) { return p[0]; }'
check array-stack-argument 42 'int f(int x, int y, int z, int u, int v, int w, int *p) { return p[0]; } int main(void) { int a[1]; a[0] = 42; return f(0,0,0,0,0,0,a); }'
check array-subscript-call-result 42 'int *id(int *p) { return p; } int main(void) { int a[2]; a[1] = 42; return id(a)[1]; }'
check array-void-pointer-conversion 42 'void *id(void *p) { return p; } int main(void) { int a[1]; a[0] = 42; int *p = id(a); return *p; }'
check array-conditional-conversion 42 'int main(void) { int a[2]; int b[2]; a[0] = 1; b[0] = 42; return (0 ? a : b)[0]; }'
check array-comma-conversion 42 'int main(void) { int a[2]; a[0] = 42; return (0, a)[0]; }'
check array-comparisons-and-logical 1 'int main(void) { int a[2]; return a == &a[0] && a != 0 && !!a && (a && a) && (0 || a); }'
check array-if-condition 42 'int main(void) { int a[1]; a[0] = 42; if (a) return a[0]; return 0; }'
check array-conditional-condition 42 'int main(void) { char a[1]; a[0] = 42; return a ? a[0] : 0; }'
check array-while-condition 42 'int main(void) { int a[1]; a[0] = 42; while (a) return a[0]; return 0; }'
check array-for-condition 42 'int main(void) { int a[1]; a[0] = 42; for (; a;) return a[0]; return 0; }'
check array-do-condition 1 'int main(void) { int a[1]; int n = 0; do { n++; } while (n < 2 && a); return n == 2; }'
check array-do-direct-condition 1 'int main(void) { int a[1]; int n = 0; do { if (++n == 2) return 1; } while (a); return 0; }'
check array-pointer-elements 42 'int main(void) { int a[2]; int b[2]; int *p[2]; p[0] = a; p[1] = b; p[1][1] = 42; return b[1]; }'
check array-pointer-element-deref 42 'int main(void) { int a[2]; int *p[1]; p[0] = a; (*p)[1] = 42; return a[1]; }'
check array-shadowing 42 'int main(void) { int a[2]; a[0] = 42; { int a[1]; a[0] = 7; } return a[0]; }'
check array-storage-separation 42 'int main(void) { char c = 7; int a[3]; char d = 9; long b[2]; a[2] = 12; b[1] = 14; return c + a[2] + d + b[1]; }'
check array-discarded-expression 42 'int main(void) { int a[1]; a; *(&a); a[0] = 42; return a[0]; }'

check_error array-assignment 'int main(void) { int a[2]; int b[2]; a = b; return 0; }' '1:40: error: invalid assignment target'
check_error array-indirect-assignment 'int main(void) { int a[2]; (*(&a)) = a; return 0; }' '1:36: error: invalid assignment target'
check_error array-prefix-increment 'int main(void) { int a[2]; ++a; return 0; }' '1:28: error: invalid increment target'
check_error array-postfix-decrement 'int main(void) { int a[2]; a--; return 0; }' '1:29: error: invalid decrement target'
check_error array-compound-assignment 'int main(void) { int a[2]; a += 1; return 0; }' '1:30: error: invalid assignment target'
check array-compound-element-assignment 42 'int main(void) { int a[2]; a[0] = 40; a[0] += 2; return a[0]; }'
check_error array-invalid-subscript 'int main(void) { int a[2]; int b[2]; return a[b]; }' '1:46: error: subscript requires a pointer and an integer'
check_error array-integer-subscript 'int main(void) { return 1[2]; }' '1:26: error: subscript requires a pointer and an integer'
check_error array-void-subscript 'void f(void); int main(void) { int a[2]; return a[f()]; }' '1:50: error: subscript requires a pointer and an integer'
check_error array-subscript-missing-rbracket 'int main(void) { int a[2]; return a[0; }' '1:38: error: expect '\'']'\'''
check_error array-invalid-product 'int main(void) { int a[2]; return a * 2; }' '1:37: error: invalid operands to integer operator'
check_error array-invalid-negation 'int main(void) { int a[2]; return -a; }' '1:35: error: invalid operand to unary -'
check_error array-invalid-complement 'int main(void) { int a[2]; return ~a; }' '1:35: error: invalid operand to unary ~'
check_error array-invalid-return 'int main(void) { int a[2]; return a; }' '1:28: error: incompatible return type'
check_error array-pointer-to-array-mismatch 'int main(void) { int a[2]; int *p = &a; return 0; }' '1:33: error: incompatible initializer type'
check_error array-call-type-mismatch 'int f(char *p); int main(void) { int a[2]; return f(a); }' '1:53: error: incompatible argument type'
check_error array-incompatible-subtraction 'int main(void) { int a[2]; char b[2]; return a - b; }' '1:48: error: pointer subtraction requires compatible types'

# Long long literal types and boundaries.
check literal-long-long-width 1 'int main(void) { return 1LL << 40 == 1099511627776L; }'
check literal-long-long-signed 1 'int main(void) { return 1LL - 2 < 0 && 0ll == 0; }'
check literal-unsigned-long-long-type 1 'int main(void) { return 1ULL - 2 > 0 && 0llu - 1 == 18446744073709551615ULL; }'
check literal-long-long-max 1 'int main(void) { long long x = 9223372036854775807LL; return x >> 62 == 1 && x > 2147483647; }'
check literal-long-long-min 1 'int main(void) { long long x = -9223372036854775807LL - 1; return x >> 63 == -1 && x < 0; }'
check literal-unsigned-long-long-max 1 'int main(void) { unsigned long long x = 18446744073709551615ULL; return x / 2 == 9223372036854775807LL && x + 1 == 0; }'
check literal-octal-long-long-small 1 'int main(void) { return 037777777777LL > -1 && 040000000000LL >> 32 == 1; }'
check literal-octal-long-long-max 1 'int main(void) { return 0777777777777777777777LL == 9223372036854775807LL; }'
check literal-octal-long-long-unsigned-fallback 1 'int main(void) { return 01000000000000000000000LL >> 63 == 1 && 01000000000000000000000LL > 0; }'
check literal-octal-long-long-unsigned-max 1 'int main(void) { return 01777777777777777777777ll == 18446744073709551615ULL; }'
check literal-long-long-mixed-signedness 1 'int main(void) { return -1LL < 1U && -1LL > 1UL && -1L > 1ULL; }'
check literal-long-long-conditional-type 1 'int main(void) { return (1 ? -1LL : 1U) < 0 && (1 ? -1LL : 1UL) > 0; }'
check literal-long-long-narrow-conversions 1 'int main(void) { unsigned u = 18446744073709551615ULL; short s = 65535LL; return u == 4294967295U && s == -1; }'
check literal-long-long-call 1 'long long f(long long x) { return x; } int main(void) { return f(9223372036854775807LL) == 9223372036854775807LL; }'
check literal-long-long-stack-argument 1 'unsigned long long f(int a, int b, int c, int d, int e, int f, unsigned long long g) { return g; } int main(void) { return f(1,2,3,4,5,6,18446744073709551615ULL) == 18446744073709551615ULL; }'
check case-long-long-max 42 'int main(void) { switch (9223372036854775807LL) { case 9223372036854775807LL: return 42; default: return 0; } }'
check case-long-long-min 42 'int main(void) { switch (-9223372036854775807LL - 1) { case -9223372036854775807LL - 1: return 42; default: return 0; } }'
check case-long-long-wraparound 42 'int main(void) { switch (0) { case 18446744073709551615ULL + 1: return 42; default: return 0; } }'
check case-long-long-mixed-signedness 42 'int main(void) { switch (1) { case -1LL < 1U: return 42; default: return 0; } }'
check literal-long-long-null-constant 1 'int main(void) { int *p = 18446744073709551615ULL + 1; return p == 0; }'
check_error literal-over-signed-long-long 'int main(void) { return 9223372036854775808LL; }' '1:25: error: integer literal out of range for supported signed types'
check_error literal-negative-over-signed-long-long 'int main(void) { return -9223372036854775808ll; }' '1:26: error: integer literal out of range for supported signed types'
check_error literal-over-uint64-long-long 'int main(void) { return 18446744073709551616ULL; }' '1:25: error: integer literal out of range for 64-bit unsigned integer'
check_error literal-over-uint64-octal-long-long 'int main(void) { return 02000000000000000000000LL; }' '1:25: error: integer literal out of range for 64-bit unsigned integer'
check_error case-long-long-overflow-add 'int main(void) { switch (0) { case 9223372036854775807LL + 1LL: return 1; } return 0; }' '1:63: error: integer overflow in constant expression'
check_error case-long-long-overflow-div 'int main(void) { switch (0) { case (-9223372036854775807LL - 1) / -1LL: return 1; } return 0; }' '1:71: error: integer overflow in constant expression'
check_error case-long-long-duplicate 'int main(void) { switch (0ULL) { case -1LL: return 1; case 18446744073709551615ULL: return 2; } return 0; }' '1:55: error: duplicate case value'

# Integer literal ranges, suffix types, and 64-bit constant expressions.
check literal-decimal-above-int 1 'int main(void) { return 2147483648 > -1; }'
check literal-decimal-uses-long 1 'int main(void) { return 4294967295 > -1 && ~4294967295 == -4294967296L; }'
check literal-minus-is-separate-operator 1 'int main(void) { return -2147483648 < 0U; }'
check literal-unsigned-int-type 1 'int main(void) { return 1U - 2 > 0 && 4294967295U + 1 == 0; }'
check literal-unsigned-promotes-to-long 1 'int main(void) { return 4294967296U >> 32 == 1 && 4294967296U > -1L == 0; }'
check literal-long-suffix-width 1 'int main(void) { return 1L << 40 == 1099511627776; }'
check literal-unsigned-long-suffix 1 'int main(void) { return 1UL - 2 > 9223372036854775807L; }'
check literal-octal-unsigned-int-type 1 'int main(void) { return 037777777777 > -1 == 0 && ~037777777777 == 0U; }'
check literal-octal-long-type 1 'int main(void) { return 040000000000 > -1 && 040000000000 >> 32 == 1; }'
check literal-octal-long-suffix 1 'int main(void) { return 037777777777L > -1 && 037777777777L >> 32 == 0; }'
check literal-octal-unsigned-long-type 1 'int main(void) { return 01000000000000000000000 >> 63 == 1; }'
check literal-octal-unsigned-long-max 1 'int main(void) { return 01777777777777777777777 == 18446744073709551615UL; }'
check literal-octal-long-selects-unsigned 1 'int main(void) { return 01000000000000000000000L > 0; }'
check literal-long-max 1 'int main(void) { long x = 9223372036854775807; return x > 2147483647 && x >> 62 == 1; }'
check literal-long-min 1 'int main(void) { long x = -9223372036854775807L - 1; return x < 0 && x >> 63 == -1; }'
check literal-unsigned-long-max 1 'int main(void) { unsigned long x = 18446744073709551615U; return x / 2 == 9223372036854775807L && x + 1 == 0; }'
check literal-suffix-case-order-large 1 'int main(void) { return 18446744073709551615ul == 18446744073709551615LU; }'
check literal-narrow-conversions 1 'int main(void) { unsigned short s = 4294967295U; unsigned u = 18446744073709551615UL; return s == 65535 && u == 4294967295U; }'
check literal-long-call 1 'long f(long x) { return x; } int main(void) { return f(4294967296L) == 4294967296L; }'
check literal-wide-stack-argument 1 'unsigned long f(int a, int b, int c, int d, int e, int f, unsigned long g) { return g; } int main(void) { return f(1,2,3,4,5,6,18446744073709551615UL) == 18446744073709551615UL; }'
check case-long-literal 42 'int main(void) { long x = 4294967296L; switch (x) { case 4294967296L: return 42; default: return 0; } }'
check case-unsigned-long-literal 42 'int main(void) { unsigned long x = 18446744073709551615UL; switch (x) { case 18446744073709551615UL: return 42; default: return 0; } }'
check case-long-min 42 'int main(void) { long x = -9223372036854775807L - 1; switch (x) { case -9223372036854775807L - 1: return 42; default: return 0; } }'
check case-unsigned-long-add-wrap 42 'int main(void) { switch (0) { case 18446744073709551615UL + 1: return 42; default: return 0; } }'
check case-unsigned-long-subtract-wrap 42 'int main(void) { unsigned long x = 18446744073709551615UL; switch (x) { case 0UL - 1: return 42; default: return 0; } }'
check case-unsigned-long-multiply-wrap 42 'int main(void) { switch (1) { case 18446744073709551615UL * 18446744073709551615UL: return 42; default: return 0; } }'
check case-long-multiply 42 'int main(void) { long x = 9223372032559808512L; switch (x) { case 4294967296L * 2147483647: return 42; default: return 0; } }'
check case-long-min-multiply 42 'int main(void) { long x = -9223372036854775807L - 1; switch (x) { case (-9223372036854775807L - 1) * 1: return 42; default: return 0; } }'
check case-unsigned-long-division 42 'int main(void) { long x = 9223372036854775807L; switch (x) { case 18446744073709551615UL / 2: return 42; default: return 0; } }'
check case-unsigned-long-remainder 42 'int main(void) { switch (1) { case 18446744073709551615UL % 7: return 42; default: return 0; } }'
check case-long-negative-division 42 'int main(void) { switch (-1) { case -4294967297L / 4294967296L: return 42; default: return 0; } }'
check case-long-add-negative 42 'int main(void) { long x = -9223372036854775807L - 1; switch (x) { case -9223372036854775807L + -1L: return 42; default: return 0; } }'
check case-long-add-min-max 42 'int main(void) { switch (-1) { case (-9223372036854775807L - 1) + 9223372036854775807L: return 42; default: return 0; } }'
check case-long-subtract 42 'int main(void) { switch (0) { case 9223372036854775807L - 9223372036854775807L: return 42; default: return 0; } }'
check case-long-shift-63 42 'int main(void) { unsigned long x = 9223372036854775808UL; switch (x) { case 1UL << 63: return 42; default: return 0; } }'
check case-unsigned-long-right-shift 42 'int main(void) { switch (1) { case 18446744073709551615UL >> 63: return 42; default: return 0; } }'
check case-long-signed-right-shift 42 'int main(void) { switch (-1) { case -1L >> 63: return 42; default: return 0; } }'
check case-long-left-shift 42 'int main(void) { long x = 1099511627776L; switch (x) { case 1L << 40: return 42; default: return 0; } }'
check case-unsigned-long-comparison 42 'int main(void) { switch (1) { case 18446744073709551615UL > 9223372036854775807L: return 42; default: return 0; } }'
check case-unsigned-long-comparison-false 42 'int main(void) { switch (0) { case 18446744073709551615UL < 1UL: return 42; default: return 0; } }'
check case-unsigned-long-narrow 42 'int main(void) { switch (-1) { case ~0UL: return 42; default: return 0; } }'
check case-unsigned-long-not 42 'int main(void) { switch (0) { case ~18446744073709551615UL: return 42; default: return 0; } }'
check case-unsigned-long-negate 42 'int main(void) { switch (1) { case -18446744073709551615UL: return 42; default: return 0; } }'
check case-long-overflow-short-circuit 42 'int main(void) { switch (0) { case 0 && (9223372036854775807L + 1L): return 42; default: return 0; } }'
check literal-unsigned-long-null-constant 1 'int main(void) { int *p = 18446744073709551615UL + 1; return p == 0; }'

check_error literal-over-uint64 'int main(void) { return 18446744073709551616UL; }' '1:25: error: integer literal out of range for 64-bit unsigned integer'
check_error literal-over-uint64-no-suffix 'int main(void) { return 18446744073709551616; }' '1:25: error: integer literal out of range for 64-bit unsigned integer'
check_error literal-over-uint64-octal 'int main(void) { return 02000000000000000000000U; }' '1:25: error: integer literal out of range for 64-bit unsigned integer'
check_error literal-over-signed-long 'int main(void) { return 9223372036854775808; }' '1:25: error: integer literal out of range for supported signed types'
check_error literal-over-signed-long-suffix 'int main(void) { return 9223372036854775808L; }' '1:25: error: integer literal out of range for supported signed types'
check_error case-long-overflow-add 'int main(void) { switch (0) { case 9223372036854775807L + 1L: return 1; } return 0; }' '1:61: error: integer overflow in constant expression'
check_error case-long-overflow-sub 'int main(void) { switch (0) { case (-9223372036854775807L - 1) - 1L: return 1; } return 0; }' '1:68: error: integer overflow in constant expression'
check_error case-long-overflow-mul 'int main(void) { switch (0) { case 9223372036854775807L * 2L: return 1; } return 0; }' '1:61: error: integer overflow in constant expression'
check_error case-long-overflow-mul-min 'int main(void) { switch (0) { case (-9223372036854775807L - 1) * -1L: return 1; } return 0; }' '1:69: error: integer overflow in constant expression'
check_error case-long-overflow-neg 'int main(void) { switch (0) { case -(-9223372036854775807L - 1): return 1; } return 0; }' '1:64: error: integer overflow in constant expression'
check_error case-long-overflow-div 'int main(void) { switch (0) { case (-9223372036854775807L - 1) / -1L: return 1; } return 0; }' '1:69: error: integer overflow in constant expression'
check_error case-long-overflow-mod 'int main(void) { switch (0) { case (-9223372036854775807L - 1) % -1L: return 1; } return 0; }' '1:69: error: integer overflow in constant expression'
check_error case-long-shift-64 'int main(void) { switch (0) { case 1L << 64: return 1; } return 0; }' '1:44: error: invalid shift count in constant expression'
check_error case-unsigned-long-shift-64 'int main(void) { switch (0) { case 1UL << 64: return 1; } return 0; }' '1:45: error: invalid shift count in constant expression'
check_error case-long-overflow-shift 'int main(void) { switch (0) { case 9223372036854775807L << 1: return 1; } return 0; }' '1:61: error: integer overflow in constant expression'
check_error case-long-shift-negative 'int main(void) { switch (0) { case -1L << 1: return 1; } return 0; }' '1:44: error: left shift of negative value in constant expression'
check_error case-unsigned-long-zero-divisor 'int main(void) { switch (0) { case 1UL / 0UL: return 1; } return 0; }' '1:45: error: division by zero in constant expression'
check_error case-long-duplicate-after-conversion 'int main(void) { switch (0) { case 4294967296L: return 1; case 0: return 2; } }' '1:59: error: duplicate case value'
check_error case-unsigned-long-duplicate 'int main(void) { unsigned long x = 0; switch (x) { case -1: return 1; case 18446744073709551615UL: return 2; } return 0; }' '1:71: error: duplicate case value'

# Full unsigned short int and unsigned long int spellings.
check unsigned-short-int-promotion 1 'int main(void) { unsigned short int x = -1; return x == 65535 && x + 1 == 65536; }'
check unsigned-short-int-truncation 1 'int main(void) { unsigned short int x = 65537; x += 65535; return x == 0; }'
check unsigned-short-int-pointer-store 1 'int main(void) { unsigned short int guard = 42; unsigned short int x = 0; unsigned short int *p = &x; return (*p = -1) == 65535 && x == 65535 && guard == 42; }'
check unsigned-short-int-function-signature 1 'unsigned short int id(unsigned short int); unsigned short int id(unsigned short int x) { return x; } int main(void) { return id(-1) == 65535 && id(65536) == 0; }'
check unsigned-long-int-width 1 'int main(void) { unsigned long int x = 1; x <<= 40; return x >> 40 == 1; }'
check unsigned-long-int-arithmetic 1 'int main(void) { unsigned long int x = -1; return x + 1 == 0 && x / 2 >> 62 == 1; }'
check unsigned-long-int-pointer-store 1 'unsigned long int *id(unsigned long int *p) { return p; } int main(void) { unsigned long int x = 1; x <<= 40; unsigned long int y = x; *id(&x) = x + 7; return x == y + 7; }'
check unsigned-long-int-function-signature 1 'unsigned long int id(unsigned long int); unsigned long int id(unsigned long int x) { return x; } int main(void) { unsigned long int x = 1; x <<= 40; return id(x) == x && id(-1) >> 63 == 1; }'
check unsigned-short-long-int-stack-arguments 1 'unsigned long int f(int a, int b, int c, int d, int e, int f, unsigned short int g, unsigned long int h) { return g + h; } int main(void) { unsigned long int x = 1; x <<= 40; return f(1,2,3,4,5,6,-1,x) == x + 65535; }'

# Short storage, conversions, and promotions use the target's 16-bit width.
check short-load 1 'int main(void) { short s = 32767; return s == 32767; }'
check short-sign-extension 1 'int main(void) { short s = -32768; return s == -32768 && s < 0; }'
check unsigned-short-zero-extension 1 'int main(void) { unsigned short s = 65535; return s == 65535 && s > 0; }'
check short-initializer-truncate 1 'int main(void) { short s = 65535; return s == -1; }'
check unsigned-short-initializer-truncate 1 'int main(void) { unsigned short s = -1; return s == 65535; }'
check short-initializer-wrap 1 'int main(void) { short s = 65536; unsigned short u = 65537; return s == 0 && u == 1; }'
check short-assignment-result 1 'int main(void) { short s = 0; unsigned short u = 0; return (s = 65535) == -1 && (u = -1) == 65535; }'
check short-adjacent-stores 1 'int main(void) { int guard = 42; short a = -1; short b = 7; b = 9; return guard == 42 && a == -1 && b == 9; }'
check short-mixed-local-layout 1 'int main(void) { char a = 42; short b = -1; char c = 7; short d = 9; d = -2; return a == 42 && b == -1 && c == 7 && d == -2; }'
check unsigned-short-integer-promotion 1 'int main(void) { unsigned short s = 65535; return s + 1 == 65536 && s > -1; }'
check unsigned-short-unary-promotion 1 'int main(void) { unsigned short s = 65535; return -s == -65535 && ~s == -65536; }'
check short-unary-division-promotion 1 'int main(void) { short s = -32768; return -s == 32768 && s / -1 == 32768; }'
check short-mixed-signs 1 'int main(void) { short s = -1; unsigned short u = 65535; return u + s == 65534 && u > s; }'
check short-unsigned-common-type 1 'int main(void) { unsigned short s = 65535; unsigned u = -1; return s < u && s + u == 65534; }'
check short-conditional-promotion 1 'int main(void) { unsigned short s = 65535; return (1 ? s : -1) == 65535 && (0 ? s : -1) < 0; }'
check short-widen-long 1 'int main(void) { short s = -1; unsigned short u = 65535; long a = s; long b = u; return a == -1 && b == 65535; }'
check long-narrow-short 1 'int main(void) { long x = 1; x <<= 40; short s = x + 65535; unsigned short u = x + 65537; return s == -1 && u == 1; }'
check unsigned-int-narrow-short 1 'int main(void) { unsigned x = -1; short s = x; unsigned short u = x; return s == -1 && u == 65535; }'
check short-char-conversions 1 'int main(void) { short s = -1; char c = s; unsigned char u = s; unsigned short v = c; return c == -1 && u == 255 && v == 65535; }'
check short-compound-truncate 1 'int main(void) { short s = 32767; s += 1; s -= 1; return s == 32767; }'
check short-compound-arithmetic 1 'int main(void) { unsigned short s = 65535; s += 1; s -= 1; s *= 2; s /= 2; s %= 7; return s == 0; }'
check short-compound-bitwise 1 'int main(void) { unsigned short s = 65535; s <<= 1; s >>= 1; s |= 7; s ^= 8; s &= 255; return s == 247; }'
check short-increment-boundaries 1 'int main(void) { short s = 32767; return s++ == 32767 && s == -32768 && --s == 32767 && ++s == -32768 && s-- == -32768 && s == 32767; }'
check unsigned-short-increment-boundaries 1 'int main(void) { unsigned short s = 65535; return s++ == 65535 && s == 0 && --s == 65535 && ++s == 0 && s-- == 0 && s == 65535; }'
check short-indirect-store 1 'int main(void) { short guard = 42; short s = 0; short *p = &s; return (*p = 65535) == -1 && s == -1 && guard == 42; }'
check short-indirect-increment 1 'int main(void) { unsigned short s = 65535; unsigned short *p = &s; return (*p)++ == 65535 && s == 0 && --*p == 65535; }'
check short-pointer-offset 42 'int main(void) { short s = 42; short *p = &s + 1; short n = -1; return *(p + n); }'
check short-condition 1 'int main(void) { unsigned short s = 32768; if (!s) return 0; return s && (0 || s) && (s ? 1 : 0); }'
check short-switch-promotion 42 'int main(void) { unsigned short s = -1; switch (s) { case -1: return 0; case 65535: return 42; default: return 0; } }'
check short-for-counter 2 'int main(void) { int n = 0; for (unsigned short s = 65534; s; s++) n++; return n; }'
check short-call-return 1 'short id(short s) { return s; } int main(void) { return id(65535) == -1 && id(32768) == -32768; }'
check unsigned-short-call-return 1 'unsigned short id(unsigned short s) { return s; } int main(void) { return id(-1) == 65535 && id(65536) == 0 && id(-1) + 1 == 65536; }'
check short-return-conversion 1 'short f(void) { return 65535; } unsigned short g(void) { return -1; } int main(void) { return f() == -1 && g() == 65535; }'
check short-six-register-arguments 1 'int f(short a, unsigned short b, short c, unsigned short d, short e, unsigned short f) { return a+b+c+d+e+f; } int main(void) { return f(-1,65535,-2,32768,-3,12345) == 110642; }'
check short-stack-arguments 1 'int f(int a, int b, int c, int d, int e, int f, short g, unsigned short h) { return a+g+h; } int main(void) { return f(1,2,3,4,5,6,32768,-1) == 32768; }'
check short-mixed-stack-arguments 1 'long f(short a, unsigned short b, char c, int d, long e, unsigned long f, int g, short h, unsigned short i) { return a+b+c+d+e+f+g+h+i; } int main(void) { long x = 1; x <<= 40; return f(-1,-1,-2,3,x,0,0,32768,32768) == x + 65535; }'
check short-parameter-address 1 'void set(short *p) { *p = -1; } short f(short s) { set(&s); return s; } int main(void) { return f(42) == -1; }'
check short-default-argument-promotion 1 'int f(); int main(void) { unsigned short s = 65535; return f(s); } int f(int s) { return s == 65535; }'
check short-nested-call 1 'unsigned short id(unsigned short s) { return s; } int main(void) { return id(id(-1)) == 65535; }'
check short-recursion 120 'short fact(short n) { if (n == 0) return 1; return n * fact(n - 1); } int main(void) { return fact(5); }'

# Short declaration specifiers.
for spec in 'short' 'short int' 'int short' 'unsigned short' 'short unsigned' \
    'unsigned short int' 'unsigned int short' 'short unsigned int' \
    'short int unsigned' 'int unsigned short' 'int short unsigned'; do
    check "short-declspecs-$spec" 42 "$spec f($spec); int main(void) { $spec x; return 42; }"
done
check short-compatible-prototypes 42 'short f(short int); short int f(int short); int main(void) { return 42; }'
check unsigned-short-compatible-prototypes 42 'unsigned short f(short unsigned int); int unsigned short f(unsigned int short); int main(void) { return 42; }'
check short-for-declaration 42 'int main(void) { for (short i; 0;) ; return 42; }'
check unsigned-short-for-declaration 42 'int main(void) { for (unsigned short i; 0;) ; return 42; }'
check short-pointer-declaration 1 'int main(void) { short x; short *p = &x; return (p + 1) - p; }'

check_error short-missing-name 'int main() { int short; return 0; }' '1:23: error: expect variable name'
check_error short-char-specifiers 'int main(void) { short char x; return 0; }' '1:24: error: invalid combination of type specifiers'
check_error char-short-specifiers 'int main(void) { char short x; return 0; }' '1:23: error: invalid combination of type specifiers'
check_error short-long-specifiers 'int main(void) { short long x; return 0; }' '1:24: error: invalid combination of type specifiers'
check_error long-short-specifiers 'int main(void) { long short x; return 0; }' '1:23: error: invalid combination of type specifiers'
check_error duplicate-short-specifier 'int main(void) { short short x; return 0; }' '1:24: error: duplicate short type specifier'
check_error short-duplicate-int 'int main(void) { short int int x; return 0; }' '1:28: error: duplicate int type specifier'
check_error short-duplicate-unsigned 'int main(void) { unsigned short unsigned x; return 0; }' '1:33: error: duplicate unsigned type specifier'
check_error short-conflicting-return 'short f(void); int f(void);' '1:20: error: conflicting declaration of function '"'"'f'"'"''
check_error short-conflicting-parameter 'int f(short); int f(int);' '1:19: error: conflicting declaration of function '"'"'f'"'"''
check_error short-conflicting-signedness 'int f(short); int f(unsigned short);' '1:19: error: conflicting declaration of function '"'"'f'"'"''
check_error short-no-prototype-promotion 'int f(); int f(short);' "1:14: error: conflicting declaration of function 'f'"
check_error short-no-prototype-promotion-reverse 'int f(short); int f();' '1:19: error: conflicting declaration of function '"'"'f'"'"''
check_error unsigned-short-no-prototype-promotion 'int f(); int f(unsigned short);' "1:14: error: conflicting declaration of function 'f'"
check_error short-incompatible-pointer 'int main(void) { int x; short *p = &x; return 0; }' '1:32: error: incompatible initializer type'
check_error short-declaration-as-statement 'int main(void) { if (1) short x; return 0; }' '1:25: error: expect statement'

# Long values exercise the upper 32 bits without requiring long literals.
check long-load-store 1 'int main(void) { long x = 1; x <<= 40; long y = x; return y >> 40 == 1; }'
check long-sign-extension 1 'int main(void) { long x = -1; long y = 0 - 1; return x < 0 && y < 0; }'
check long-zero-extension 1 'int main(void) { unsigned x = -1; long y = x; return y > 2147483647 && y >> 32 == 0; }'
check long-int-min-extension 1 'int main(void) { long x = -2147483647 - 1; return x < -2147483647; }'
check unsigned-long-sign-extension 1 'int main(void) { unsigned long x = -1; return x >> 63 == 1; }'
check long-assignment-result 1 'int main(void) { long x = 1; x <<= 40; long y; return (y = x) == x && y >> 40 == 1; }'
check long-add-subtract-multiply 1 'int main(void) { long x = 1; x <<= 40; return x + x == x * 2 && x + 7 - x == 7; }'
check long-divmod 1 'int main(void) { long x = 1; x <<= 40; return (x * 6) / 3 == x * 2 && (x + 5) % x == 5; }'
check long-negative-divmod 1 'int main(void) { long x = 1; x <<= 40; return (-x - 5) / x == -1 && (-x - 5) % x == -5; }'
check unsigned-long-divmod 1 'int main(void) { unsigned long x = -1; return x / 2 >> 62 == 1 && x % 2 == 1; }'
check unsigned-long-wraparound 1 'int main(void) { unsigned long x = -1; return x + 1 == 0 && x * x == 1 && -x == 1; }'
check long-comparisons 1 'int main(void) { long x = 1; x <<= 40; return x != 0 && x > 2147483647 && x >= x && 0 < x && 0 <= x; }'
check unsigned-long-comparisons 1 'int main(void) { unsigned long x = -1; long y = -1; return x > 0 && x >= y && y > 0 - x && x == y; }'
check long-unsigned-int-common-type 1 'int main(void) { long x = -1; unsigned y = 1; return x < y && x + y == 0 && x <= y; }'
check long-unsigned-long-common-type 1 'int main(void) { long x = -1; unsigned long y = 1; return x > y && x + y == 0; }'
check long-unsigned-bitwise-conversion 1 'int main(void) { long x = 0; unsigned y = -1; return (x | y) >> 32 == 0 && (x ^ y) >> 32 == 0; }'
check long-bitwise 1 'int main(void) { long x = 1; x <<= 40; return (x | 3) == x + 3 && (x ^ 3) == x + 3 && ((x | 3) & x) == x; }'
check long-unary 1 'int main(void) { long x = 1; x <<= 40; return ~x == -x - 1 && -x < 0; }'
check long-signed-shift 1 'int main(void) { long x = -1; unsigned y = 40; return x >> y == -1; }'
check unsigned-long-shifts 1 'int main(void) { unsigned long x = -1; return x >> 63 == 1 && x << 63 >> 63 == 1; }'
check int-shift-long-count 1 'int main(void) { long n = 1; return (-4 >> n) == -2; }'
check long-conditional-type 1 'int main(void) { long x = 1; x <<= 40; return (1 ? x : 0) == x && (0 ? 0 : x) == x; }'
check long-conditional-signedness 1 'int main(void) { long x = -1; unsigned y = 0; return (1 ? x : y) < 0 && (0 ? y : x) < 0; }'
check long-logical 1 'int main(void) { long x = 1; x <<= 40; return !x == 0 && !!x && (x && 1) && (0 || x); }'
check long-if-condition 42 'int main(void) { long x = 1; x <<= 32; if (x) return 42; return 0; }'
check long-conditional-condition 42 'int main(void) { long x = 1; x <<= 32; return x ? 42 : 0; }'
check long-while-condition 42 'int main(void) { long x = 1; x <<= 32; while (x) { x = 0; return 42; } return 0; }'
check long-for-condition 42 'int main(void) { long x = 1; x <<= 32; for (; x;) { x = 0; return 42; } return 0; }'
check long-do-condition 2 'int main(void) { long x = 1; x <<= 32; int n = 0; do { n++; if (n == 2) x = 0; } while (x); return n; }'
check long-switch-full-width 42 'int main(void) { long x = 1; x <<= 32; switch (x) { case 0: return 0; default: return 42; } }'
check long-switch-negative 42 'int main(void) { long x = -1; switch (x) { case -1: return 42; default: return 0; } }'
check unsigned-long-switch-negative 42 'int main(void) { unsigned long x = -1; switch (x) { case -1: return 42; default: return 0; } }'
check long-narrow-int 1 'int main(void) { long x = 1; x <<= 40; int y = x + 42; unsigned z = x + 43; return y == 42 && z == 43; }'
check long-narrow-char 1 'int main(void) { long x = -1; char c = x; unsigned char u = x; return c == -1 && u == 255; }'
check long-widen-char 1 'int main(void) { char c = -1; unsigned char u = 255; long x = c; long y = u; return x == -1 && y == 255; }'
check long-compound-arithmetic 1 'int main(void) { long x = 1; x <<= 40; long y = x; x += 7; x -= 1; x *= 3; x /= 3; return x == y + 6; }'
check long-compound-bitwise 1 'int main(void) { unsigned long x = -1; x >>= 32; x <<= 8; x |= 15; x ^= 8; x &= -1; x %= 16; return x == 7; }'
check long-increment 1 'int main(void) { long x = 1; x <<= 40; long y = x; return x++ == y && ++x == y + 2 && x-- == y + 2 && --x == y; }'
check unsigned-long-increment 1 'int main(void) { unsigned long x = -1; return x++ != 0 && x == 0 && --x != 0; }'
check long-indirect-load-store-increment 1 'int main(void) { long x = 1; x <<= 40; long *p = &x; long y = *p; *p = x + 7; return x == y + 7 && (*p)++ == y + 7 && --*p == y + 7; }'
check long-pointer-offset 42 'int main(void) { long x = 42; long *p = &x + 1; long n = -1; return *(p + n); }'
check pointer-difference-long-type 1 'int main(void) { long x; unsigned y = 0; return (&x - (&x + 1)) < y; }'
check long-call-return 1 'long id(long x) { return x; } int main(void) { long x = 1; x <<= 40; return id(x) == x && id(-1) < 0; }'
check unsigned-long-call-return 1 'unsigned long id(unsigned long x) { return x; } int main(void) { return id(-1) >> 63 == 1; }'
check long-return-int-conversion 1 'long f(void) { return -1; } int main(void) { return f() < 0; }'
check long-return-narrow-conversion 1 'int f(long x) { return x; } int main(void) { long x = 1; x <<= 40; return f(x + 42) == 42; }'
check long-default-argument 1 'long id(); int main(void) { long x = 1; x <<= 40; return id(x) == x; } long id(long x) { return x; }'
check long-eight-arguments 1 'long sum(long a, long b, long c, long d, long e, long f, long g, long h) { return a+b+c+d+e+f+g+h; } int main(void) { long x = 1; x <<= 40; return sum(x,x,x,x,x,x,x,x) == x * 8; }'
check long-mixed-arguments 1 'long f(int a, char b, long c, unsigned d, unsigned long e, char f, long g, unsigned long h) { return c + g + h - e + a + b + d + f; } int main(void) { long x = 1; x <<= 40; return f(1,2,x,3,x,4,x,x) == x * 2 + 10; }'
check long-recursion 1 'long f(long x, int n) { if (n) return f(x + 1, n - 1); return x; } int main(void) { long x = 1; x <<= 40; return f(x, 3) == x + 3; }'
check long-nested-calls 1 'long f(long x) { return x + 1; } int main(void) { long x = 1; x <<= 40; return x + f(f(x)) == x * 2 + 2; }'

# Long declaration specifiers.
for spec in 'long' 'long int' 'int long' 'unsigned long' 'long unsigned' \
    'unsigned long int' 'unsigned int long' 'long unsigned int' \
    'long int unsigned' 'int unsigned long' 'int long unsigned'; do
    check "long-declspecs-$spec" 42 "$spec f($spec); int main(void) { $spec x; return 42; }"
done
check long-compatible-prototypes 42 'long f(long int); long int f(int long); int main(void) { return 42; }'
check unsigned-long-compatible-prototypes 42 'unsigned long f(long unsigned int); int unsigned long f(unsigned int long); int main(void) { return 42; }'
check long-for-declaration 42 'int main(void) { for (long i; 0;) ; return 42; }'
check unsigned-long-for-declaration 42 'int main(void) { for (unsigned long i; 0;) ; return 42; }'
check long-pointer-declaration 1 'int main(void) { long x; long *p = &x; return (p + 1) - p; }'

check_error long-missing-name 'int main() { int long; return 0; }' '1:22: error: expect variable name'
check_error long-char-specifiers 'int main(void) { long char x; return 0; }' '1:23: error: invalid combination of type specifiers'
check_error char-long-specifiers 'int main(void) { char long x; return 0; }' '1:23: error: invalid combination of type specifiers'
check_error long-long-long-specifiers 'int main(void) { long long long x; return 0; }' '1:28: error: duplicate long type specifier'
check_error long-duplicate-int 'int main(void) { long int int x; return 0; }' '1:27: error: duplicate int type specifier'
check_error long-duplicate-unsigned 'int main(void) { unsigned long unsigned x; return 0; }' '1:32: error: duplicate unsigned type specifier'
check_error long-conflicting-return 'long f(void); int f(void);' '1:19: error: conflicting declaration of function '"'"'f'"'"''
check_error long-conflicting-parameter 'int f(long); int f(int);' '1:18: error: conflicting declaration of function '"'"'f'"'"''
check_error long-conflicting-signedness 'long f(long); unsigned long f(long);' '1:29: error: conflicting declaration of function '"'"'f'"'"''
check_error long-conflicting-parameter-signedness 'int f(long); int f(unsigned long);' '1:18: error: conflicting declaration of function '"'"'f'"'"''
check_error long-incompatible-pointer 'int main(void) { int x; long *p = &x; return 0; }' '1:31: error: incompatible initializer type'
check_error long-declaration-as-statement 'int main(void) { if (1) long x; return 0; }' '1:25: error: expect statement'

# Long long declaration specifiers, including nonadjacent long keywords.
for spec in 'long long' 'long long int' 'long int long' 'int long long' \
    'unsigned long long' 'long unsigned long' 'long long unsigned' \
    'unsigned int long long' 'unsigned long int long' 'unsigned long long int' \
    'int unsigned long long' 'int long unsigned long' 'int long long unsigned' \
    'long unsigned int long' 'long unsigned long int' 'long int unsigned long' \
    'long int long unsigned' 'long long unsigned int' 'long long int unsigned'; do
    check "long-long-declspecs-$spec" 42 "$spec f($spec); $spec f($spec x) { return x; } int main(void) { $spec x = 42; return f(x); }"
done
check long-long-for-declaration 42 'int main(void) { for (long long i = 42; i;) return i; return 0; }'
check unsigned-long-long-for-declaration 42 'int main(void) { for (unsigned long long i = 42; i;) return i; return 0; }'
check long-long-pointer-declaration 42 'int main(void) { long long x = 42; long long *p = &x; return *p; }'
check long-long-common-type-width 1 'int main(void) { long long x = 1; x <<= 40; return x + x == 2199023255552L; }'
check long-long-unsigned-int-common-type 1 'int main(void) { long long x = -1; unsigned y = 1; return x < y; }'
check long-long-unsigned-long-common-type 1 'int main(void) { long long x = -1; unsigned long y = 1; return x > y; }'
check long-unsigned-long-long-common-type 1 'int main(void) { long x = -1; unsigned long long y = 1; return x > y; }'
check_error long-long-short-specifiers 'int main(void) { long long short x; return 0; }' '1:28: error: invalid combination of type specifiers'
check_error long-long-char-specifiers 'int main(void) { long long char x; return 0; }' '1:28: error: invalid combination of type specifiers'
check_error long-long-duplicate-int 'int main(void) { long long int int x; return 0; }' '1:32: error: duplicate int type specifier'
check_error long-long-duplicate-unsigned 'int main(void) { unsigned long long unsigned x; return 0; }' '1:37: error: duplicate unsigned type specifier'
check_error long-long-conflicting-return 'long f(void); long long f(void);' '1:25: error: conflicting declaration of function '"'"'f'"'"''
check_error long-long-conflicting-parameter 'int f(long); int f(long long);' '1:18: error: conflicting declaration of function '"'"'f'"'"''
check_error long-long-conflicting-signedness 'int f(long long); int f(unsigned long long);' '1:23: error: conflicting declaration of function '"'"'f'"'"''
check_error long-long-incompatible-pointer 'int main(void) { long x; long long *p = &x; return 0; }' '1:37: error: incompatible initializer type'

# Unsigned char occupies one byte and promotes to int.
check unsigned-char-load 255 'int main(void) { unsigned char c = -1; return c; }'
check char-unsigned-order 255 'int main(void) { char unsigned c = -1; return c; }'
check unsigned-char-high-bit 1 'int main(void) { unsigned char c = 128; return c > 0 && c == 128; }'
check unsigned-char-truncate 1 'int main(void) { unsigned char c = 511; return c == 255; }'
check unsigned-char-truncate-zero 1 'int main(void) { unsigned char c = 256; return c == 0; }'
check unsigned-char-assignment-result 1 'int main(void) { unsigned char c = 0; return (c = -1) == 255 && c == 255; }'
check unsigned-char-integer-promotion 1 'int main(void) { unsigned char c = 255; return c + 1 == 256 && c - 256 == -1; }'
check unsigned-char-unary-promotion 1 'int main(void) { unsigned char c = 255; return ~c == -256 && -c == -255; }'
check unsigned-char-shift-promotion 1 'int main(void) { unsigned char c = 255; return c / 2 == 127 && (c >> 1) == 127 && (c << 1) == 510; }'
check unsigned-char-conditional-promotion 1 'int main(void) { unsigned char c = 255; return (1 ? c : -1) == 255 && (0 ? c : -1) < 0; }'
check unsigned-char-signed-char-mix 1 'int main(void) { unsigned char c = 255; char s = -1; return c > s && c + s == 254; }'
check unsigned-char-unsigned-mix 1 'int main(void) { unsigned char c = 255; unsigned u = 0; return c < -1 == 0 && c > u && c + u == 255; }'
check unsigned-char-signed-conversion 1 'int main(void) { unsigned char c = 255; char s = c; unsigned char d = s; return s == -1 && d == 255; }'
check unsigned-char-compound-truncate 1 'int main(void) { unsigned char c = 255; c += 1; c -= 1; c *= 2; return c == 254; }'
check unsigned-char-compound-divmod 1 'int main(void) { unsigned char c = 255; c >>= 1; c /= 2; c %= 7; return c == 0; }'
check unsigned-char-increment 1 'int main(void) { unsigned char c = 255; return c++ == 255 && c == 0 && --c == 255 && ++c == 0 && c-- == 0 && c == 255; }'
check unsigned-char-pointer-store 1 'int main(void) { unsigned char c = 128; unsigned char *p = &c; return *p == 128 && (*p = -1) == 255 && c == 255; }'
check unsigned-char-pointer-increment 1 'int main(void) { unsigned char c = 255; unsigned char *p = &c; return (*p)++ == 255 && c == 0 && --*p == 255; }'
check unsigned-char-pointer-size 1 'int main(void) { unsigned char c = 255; unsigned char *p = &c; return (p + 1) - p == 1; }'
check unsigned-char-call-signatures 1 'unsigned char id(char unsigned c); char unsigned id(unsigned char c) { return c; } int main(void) { return id(-1) == 255 && id(256) == 0; }'
check unsigned-char-return 1 'unsigned char f(void) { return -1; } int main(void) { return f() > 0 && f() + 1 == 256; }'
check unsigned-char-argument-truncate 1 'int f(unsigned char c) { return c == 255; } int main(void) { return f(511); }'
check unsigned-char-stack-arguments 1 'int f(int a, int b, int c, int d, int e, int f, unsigned char g, unsigned char h) { return g == 255 && h == 128; } int main(void) { return f(1, 2, 3, 4, 5, 6, -1, 384); }'
check unsigned-char-default-promotion 1 'int f(); int main(void) { unsigned char c = 255; return f(c); } int f(int c) { return c == 255; }'
check unsigned-char-switch-promotion 42 'int main(void) { unsigned char c = -1; switch (c) { case 255: return 42; case -1: return 1; default: return 0; } }'
check unsigned-char-for-declaration 1 'int main(void) { int n = 0; for (char unsigned c = 254; c; c++) n++; return n == 2; }'

check_error duplicate-char-specifier 'int main(void) { char char c; return 0; }' '1:23: error: duplicate char type specifier'
check_error unsigned-char-int-specifier 'int main(void) { unsigned char int c; return 0; }' '1:32: error: invalid combination of type specifiers'
check_error int-unsigned-char-specifier 'int main(void) { int unsigned char c; return 0; }' '1:31: error: invalid combination of type specifiers'
check_error unsigned-char-duplicate-unsigned 'int main(void) { unsigned char unsigned c; return 0; }' '1:32: error: duplicate unsigned type specifier'
check_error unsigned-char-conflicting-param 'int f(unsigned char); int f(char);' '1:27: error: conflicting declaration of function '"'"'f'"'"''
check_error unsigned-char-conflicting-return 'unsigned char f(void); char f(void);' '1:29: error: conflicting declaration of function '"'"'f'"'"''
check_error unsigned-char-prototype-promotion 'int f(); int f(unsigned char);' "1:14: error: conflicting declaration of function 'f'"
check_error unsigned-char-prototype-promotion-reverse 'int f(unsigned char); int f();' '1:27: error: conflicting declaration of function '"'"'f'"'"''
check_error unsigned-char-incompatible-pointer 'int main(void) { char c; unsigned char *p = &c; return 0; }' '1:41: error: incompatible initializer type'

# Unsigned arithmetic and the usual arithmetic conversions.
check unsigned-high-bit 1 'int main(void) { unsigned u = -1; return u > 2147483647; }'
check unsigned-mixed-comparison 1 'int main(void) { unsigned u = 0; return -1 > u; }'
check unsigned-mixed-equality 1 'int main(void) { unsigned u = -1; return u == -1; }'
check unsigned-relations 1 'int main(void) { unsigned u = 0; return u < -1 && u <= -1 && -1 >= u; }'
check unsigned-relations-false 0 'int main(void) { unsigned u = -1; return u < 0 || u <= 0 || 0 > u || 0 >= u; }'
check unsigned-wraparound 1 'int main(void) { unsigned u = -1; return u + 1 == 0 && u * u == 1; }'
check unsigned-subtract-type 1 'int main(void) { unsigned u = 0; return u - 1 > 0; }'
check unsigned-divmod 1 'int main(void) { unsigned u = -1; return u / 2 == 2147483647 && u % 3 == 0; }'
check unsigned-mixed-divmod 1 'int main(void) { unsigned u = -1; return u / -1 == 1 && u % -1 == 0; }'
check unsigned-right-shift 1 'int main(void) { unsigned u = -1; return (u >> 1) == 2147483647; }'
check signed-shift-unsigned-count 1 'int main(void) { unsigned n = 1; return (-4 >> n) == -2; }'
check unsigned-left-shift 1 'int main(void) { unsigned u = 1; return (u << 31) > 0; }'
check unsigned-unary-type 1 'int main(void) { unsigned u = 1; return -u > 0 && ~u > 0; }'
check unsigned-conditional-type 1 'int main(void) { unsigned u = 0; return (1 ? -1 : u) > 0 && (0 ? u : -1) > 0; }'
check unsigned-char-promotion 1 'int main(void) { unsigned u = 0; char c = -1; return c > u && (c + u) > 0; }'
check unsigned-conversion 1 'int main(void) { unsigned u = -1; char c = u; int i = u; return c == -1 && i == -1 && i < 0; }'
check unsigned-assignment-value 1 'int main(void) { unsigned u = 0; return (u = -1) > 0; }'
check unsigned-compound-arithmetic 1 'int main(void) { unsigned u = -1; u += 1; u -= 1; u *= 2; u /= 2; return u == 2147483647; }'
check unsigned-compound-divmod-shift 1 'int main(void) { unsigned u = -1; u >>= 1; u %= 7; return u == 1; }'
check unsigned-bitwise-type 1 'int main(void) { unsigned u = 0; return (u | -1) > 0 && (u ^ -1) > 0 && ((u - 1) & -1) > 0; }'
check unsigned-logical 1 'int main(void) { unsigned u = -1; return !u == 0 && (u && 1) == 1 && (u || 0) == 1; }'
check unsigned-comparison-result-int 1 'int main(void) { unsigned u = -1; return (u > 0) - 2 < 0; }'
check unsigned-increment 1 'int main(void) { unsigned u = -1; return u++ > 0 && u == 0 && --u > 0 && ++u == 0 && u-- == 0 && u > 0; }'
check unsigned-dereference 1 'int main(void) { unsigned u = -1; unsigned *p = &u; *p = *p / 2; return *p == 2147483647; }'
check unsigned-increment-dereference 1 'int main(void) { unsigned u = -1; unsigned *p = &u; return (*p)++ > 0 && u == 0 && --*p > 0; }'
check unsigned-call-return 1 'unsigned id(unsigned u) { return u; } int main(void) { return id(-1) / 2 == 2147483647; }'
check unsigned-return-conversion 1 'unsigned f(void) { return -1; } int g(int x) { return x < 0; } int main(void) { return g(f()); }'
check unsigned-stack-arguments 1 'unsigned f(int a, int b, int c, int d, int e, int f, unsigned g, unsigned h) { return g / h; } int main(void) { return f(1, 2, 3, 4, 5, 6, -1, 2) == 2147483647; }'
check unsigned-pointer-offset 1 'int main(void) { int x = 42; int *p = &x; unsigned u = 1; return *((p + u) - u) == 42; }'
check unsigned-switch-negative-case 42 'int main(void) { unsigned u = -1; switch (u) { case -1: return 42; default: return 0; } }'
check char-switch-promotion 42 'int main(void) { char c = -1; switch (c) { case -1: return 42; default: return 0; } }'

check_error unsigned-switch-duplicate 'int main(void) { unsigned u = 0; switch (u) { case -1: return 1; case ~0: return 2; } return 0; }' '1:66: error: duplicate case value'
check_error switch-pointer 'int main(void) { int x; switch (&x) { default: return 0; } }' '1:33: error: switch condition must have integer type'
check_error case-overflow-mod 'int main(void) { switch (0) { case (-2147483647 - 1) % -1: return 1; } return 0; }' '1:58: error: integer overflow in constant expression'

# Both orders of the unsigned int declaration specifiers denote one type.
check unsigned-int-local 42 'int main(void) { unsigned int x = 42; return x; }'
check int-unsigned-local 42 'int main(void) { int unsigned x = 42; return x; }'
check unsigned-specifier-signatures 42 'unsigned int id(int unsigned x); int unsigned id(unsigned int x) { return x; } int main(void) { return id(42); }'
check unsigned-specifier-pointers 42 'unsigned int *id(int unsigned *p) { return p; } int main(void) { unsigned int x = 42; int unsigned *p = &x; return *id(p); }'
check unsigned-specifier-for 42 'int main(void) { int n = 0; for (int unsigned i = 0; i < 6; i++) n += 7; return n; }'
check_error unsigned-missing-name 'int main() { int unsigned; return 0; }' '1:26: error: expect variable name'
check_error duplicate-int-specifier 'int main(void) { int int x; return 0; }' '1:22: error: duplicate int type specifier'
check_error duplicate-unsigned-specifier 'int main(void) { unsigned unsigned x; return 0; }' '1:27: error: duplicate unsigned type specifier'
check_error duplicate-int-after-unsigned 'int main(void) { int unsigned int x; return 0; }' '1:31: error: duplicate int type specifier'
check_error duplicate-unsigned-after-int 'int main(void) { unsigned int unsigned x; return 0; }' '1:31: error: duplicate unsigned type specifier'
check_error invalid-unsigned-void 'int main(void) { unsigned void x; return 0; }' '1:27: error: invalid combination of type specifiers'

# Diagnostic locations audited against GCC and Clang. Expected diagnostics
# check our filename, line, and byte column.
check_error location-return-semicolon $'int main(void) {\n  return 42\n}\n' '2:12: error: expect '\'';'\'''
check_error location-decl-semicolon $'int main(void) {\n  int a = 3\n  return a;\n}\n' '2:12: error: expect '\'';'\'''
check_error location-expression-semicolon $'int main(void) {\n  int a;\n  a = 3\n  return a;\n}\n' '3:8: error: expect '\'';'\'''
check_error location-semicolon-after-comment $'int main(void) {\n  return 42 /* comment\n  spans lines */\n}\n' '2:12: error: expect '\'';'\'''
check_error location-missing-member-semicolon $'struct S {\n  int x\n};\n' '2:8: error: expect '\'';'\'''
check_error location-break-semicolon $'int main(void) {\n  while (1) {\n    break\n  }\n}\n' '3:10: error: expect '\'';'\'''
check_error location-continue-semicolon $'int main(void) {\n  while (1) {\n    continue\n  }\n}\n' '3:13: error: expect '\'';'\'''
check_error location-goto-semicolon $'int main(void) {\n  L: ;\n  goto L\n}\n' '3:9: error: expect '\'';'\'''
check_error location-do-semicolon $'int main(void) {\n  do {} while (0)\n}\n' '2:18: error: expect '\'';'\'''
check_error location-string-token-end $'int main(void) {\n  char *p = "a\\n" "bc"\n  return 0;\n}\n' '2:23: error: expect '\'';'\'''
check_error location-return-keyword $'int main(void) {\n  return;\n}\n' '2:3: error: expect return expr'
check_error location-unnamed-parameter $'int f(\n  int,\n  char\n) { return 0; }' '2:3: error: expect parameter name in function definition'
check_error location-unnamed-array-parameter $'int f(\n  int [2]\n) { return 0; }' '2:3: error: expect parameter name in function definition'
check_error location-missing-array-variable-name $'int main(void) {\n  int [3];\n}\n' '2:7: error: expect variable name'
check_error location-missing-array-member-name $'struct S {\n  int [3];\n};\n' '2:7: error: expect member name'
check_error location-missing-pointer-name $'int main(void) {\n  int *;\n}\n' '2:8: error: expect variable name'
check_error location-bad-parameter $'int f(\n  int +\n) { return 0; }' '2:7: error: expect parameter name'
check_error location-expression-lf $'int main(void) {\n  return 1 +;\n}\n' '2:13: error: expect expr'
check_error location-expression-crlf $'int main(void) {\r\n  return 1 +;\r\n}\r\n' '2:13: error: expect expr'
check_error location-expression-cr $'int main(void) {\r  return 1 +;\r}\r' '2:13: error: expect expr'
check_error location-expression-tab $'int main(void) {\n\treturn 1 +;\n}\n' '2:12: error: expect expr'
check_error location-expression-utf8-comment $'int main(void) {\n  /* 中文 */ return 1 +;\n}\n' '2:26: error: expect expr'
check_error location-expression-comment $'int main(void) {\n  /* comment\n  end */ return 1 +;\n}\n' '3:20: error: expect expr'
check_error location-comment-start $'int main(void) {\n  /* broken\n  comment\n' '2:3: error: unterminated comment'
check_error location-comment-only $'/*' '1:1: error: unterminated comment'
check_error location-missing-rparen $'int main(void) {\n  return (1 + 2\n    ;\n}\n' '3:5: error: expect '\'')'\'''
check_error location-missing-rbracket $'int main(void) {\n  int a[2\n  ;\n}\n' '3:3: error: expect '\'']'\'''
check_error location-missing-colon $'int main(void) {\n  return 1 ? 2\n    ;\n}\n' '3:5: error: expect '\'':'\'''
check_error location-member-name $'struct S { int x; };\nint main(void) {\n  struct S s;\n  return s.\n    ;\n}\n' '5:5: error: expect member name'
check_error location-arrow-name $'struct S { int x; };\nint main(void) {\n  struct S *p;\n  return p->\n    ;\n}\n' '5:5: error: expect member name'
check_error location-function-eof $'int main(void) {\n  return 0;\n\n' '4:1: error: expect '\''}'\'''
check_error location-struct-eof $'struct S {\n  int x;\n\n' '4:1: error: expect '\''}'\'''
check_error location-empty-condition $'int main(void) {\n  if (\n    ) return 0;\n}\n' '3:5: error: expect expr'
check_error location-for-separator $'int main(void) {\n for (1) return 0;\n}\n' '2:8: error: expect '\'';'\'''
check_error location-call-comma $'int f(int x);\nint main(void) {\n  return f(1,\n    );\n}\n' '4:5: error: expect expr'
check_error location-subscript-expression $'int main(void) {\n  int a[2];\n  return a[\n    ];\n}\n' '4:5: error: expect expr'
check_error location-label-name $'int main(void) {\n  goto\n    ;\n}\n' '3:5: error: expect label name'
check_error location-unterminated-string $'int main(void) {\n  return "abc\n}\n' '2:10: error: unterminated string literal'
check_error location-unterminated-character $'int main(void) {\n  return \'a\n}\n' '2:10: error: unterminated character literal'

check_error missing-plus-rhs 'int main() { return 1 +; }' '1:24: error: expect expr'
check_error missing-sub-rhs 'int main() { return 1 -; }' '1:24: error: expect expr'
check_error missing-mul-rhs 'int main() { return 1 *; }' '1:24: error: expect expr'
check_error missing-div-rhs 'int main() { return 1 /; }' '1:24: error: expect expr'
check_error missing-neg-operand 'int main() { return -; }' '1:22: error: expect expr'
check_error missing-not-operand 'int main() { return !; }' '1:22: error: expect expr'
check_error missing-bitnot-operand 'int main() { return ~; }' '1:22: error: expect expr'
check_error missing-unary-chain 'int main() { return !~-; }' '1:24: error: expect expr'
check_error empty-parens 'int main() { return (); }' '1:22: error: expect expr'
check_error nested-empty-parens 'int main() { return (()); }' '1:23: error: expect expr'
check_error empty-rhs 'int main() { return 1 + (); }' '1:26: error: expect expr'
check_error empty-lhs 'int main() { return () + 1; }' '1:22: error: expect expr'
check_error unexpected-mul 'int main() { return * 2; }' '1:21: error: invalid deref target'
check_error double-operator 'int main() { return 1 + * 2; }' '1:25: error: invalid deref target'
check_error unknown-operand 'int main() { return @; }' '1:21: error: expect expr'
check_error keyword-operand 'int main() { return return; }' '1:21: error: expect expr'
check_error unexpected-close 'int main() { return ); }' '1:21: error: expect expr'
check_error missing-rhs-eof 'int main() { return 1 + }' '1:25: error: expect expr'
check_error missing-neg-eof 'int main() { return - }' '1:23: error: expect expr'
check_error missing-expr-eof 'int main() { return }' '1:21: error: expect expr'
check_error missing-rparen 'int main() { return (1 + 2; }' "1:27: error: expect ')'"
check_error missing-rparen-eof 'int main() { return (1 + 2 }' "1:28: error: expect ')'"
check_error missing-semicolon 'int main() { return 42 }' "1:23: error: expect ';'"
check_error extra-rparen 'int main() { return (1+2)); }' "1:26: error: expect ';'"
check_error adjacent-literals 'int main() { return 1 2; }' "1:22: error: expect ';'"
check_error trailing-identifier 'int main() { return 42; garbage }' "1:25: error: undeclared identifier"
check_error trailing-token 'int main() { return 42; @ }' "1:25: error: expect expr"
check_error trailing-after-bare-return 'int main() { return; garbage }' '1:14: error: expect return expr'
check_error empty-input '' "1:1: error: expect type specifier"
check_error whitespace-only $' \t\n' "2:1: error: expect type specifier"
check_error undeclared-read 'int main() { return a; }' '1:21: error: undeclared identifier'
check_error undeclared-assign 'int main() { a = 3; return 0; }' '1:14: error: undeclared identifier'
check_error use-before-declared 'int main() { a=3; int a; return a; }' '1:14: error: undeclared identifier'
check_error duplicate-local 'int main() { int a; int a; return 0; }' '1:25: error: duplicate local variable'
check_error duplicate-init 'int main() { int a = 2; int a = 3; return a; }' '1:29: error: duplicate local variable'
check_error out-of-scope 'int main() { { int a = 42; } return a; }' '1:37: error: undeclared identifier'
check_error sibling-out-of-scope 'int main() { { int a = 9; } { return a; } }' '1:38: error: undeclared identifier'
check_error invalid-lvalue-literal 'int main() { 1=3; return 0; }' '1:15: error: invalid assignment target'
check_error invalid-lvalue-sum 'int main() { int a; (a + 1) = 3; return 0; }' '1:29: error: invalid assignment target'
check_error invalid-lvalue-unary 'int main() { int a; -a = 3; return 0; }' '1:24: error: invalid assignment target'
check_error bad-assign-rhs 'int main() { int a; a =; return 0; }' '1:24: error: expect expr'
check_error bad-assign-rhs-eof 'int main() { int a; a=' '1:23: error: expect expr'
check_error missing-decl-name 'int main() { int = 3; return 0; }' '1:18: error: expect variable name'
check_error missing-decl-semicolon 'int main() { int a = 3 return a; }' "1:23: error: expect ';'"
check_error missing-decl-init 'int main() { int a =; return 0; }' '1:21: error: expect expr'
check_error nested-invalid 'int main() { int a; { int a; int a; } }' '1:34: error: duplicate local variable'
check_error bad-assignment-nested 'int main() { int a; a = 1 = 2; }' '1:27: error: invalid assignment target'
check_error missing-expr-semicolon 'int main() { int a; a = 3 return a; }' "1:26: error: expect ';'"
check_error missing-identifier-after-int 'int main() { int; return 0; }' '1:17: error: expect variable name'
check_error declare-keyword 'int main() { int return; return 0; }' '1:18: error: expect variable name'
check_error use-post-scope-shadow 'int main() { { int x = 1; } x = 42; return 0; }' '1:29: error: undeclared identifier'
check_error redecl-after-nested 'int main() { int a; { int a; } int a; }' '1:36: error: duplicate local variable'
check_error unsupported-comma-decl 'int main() { int a, b; return 0; }' "1:19: error: expect ';'"
check discarded-comparison-expression 42 'int main() { int a = 42; a == 3; return a; }'
check_error invalid-int-char-specifiers 'int main() { int char; return 0; }' '1:18: error: invalid combination of type specifiers'
for kw in \
    _Alignas _Alignof _Atomic _Complex _Generic _Imaginary \
	     _Noreturn _Static_assert _Thread_local \
	     auto break case continue default do double else \
	     float for goto if inline register restrict signed sizeof \
	     switch union volatile while; do
    check_error "reserved-kw-$kw" \
		"int main() { int $kw; return 0; }" \
		'1:18: error: expect variable name'
done
for kw in _Bool enum struct void; do
    check_error "reserved-kw-$kw" \
                "int main() { int $kw; return 0; }" \
                '1:18: error: invalid combination of type specifiers'
done
check_error reserved-kw-typedef 'int main() { int typedef; return 0; }' \
            '1:25: error: expect typedef name'
check_error invalid-increment 'int main() { return ++1; }' \
	    '1:21: error: invalid increment target'
check_error invalid-increment 'int main() { return 1++; }' \
	    '1:22: error: invalid increment target'
check_error invalid-increment 'int main() { int a; return ++(a+1); }' \
	    '1:28: error: invalid increment target'
check_error invalid-decrement 'int main() { return --1; }' \
	    '1:21: error: invalid decrement target'
check_error invalid-postfix-chain 'int main() { int a; return (a++)++; }' \
	    '1:33: error: invalid increment target'
check_error undeclared-postfix 'int main() { a++; return 0; }' \
	    '1:14: error: undeclared identifier'
check_error missing-compare-rhs 'int main() { return 1 <; }' \
	    '1:24: error: expect expr'
check_error missing-eq-rhs 'int main() { return 1 ==; }' \
	    '1:25: error: expect expr'
check_error compound-assign-literal 'int main() { 1 += 2; return 0; }' \
	    '1:16: error: invalid assignment target'
check_error compound-assign-sum 'int main() { int a; a + 1 += 2; }' \
	    '1:27: error: invalid assignment target'
check_error missing-shift-rhs 'int main() { return 1 <<; }' \
	    '1:25: error: expect expr'
check_error shift-assign-literal 'int main() { 1 <<= 2; return 0; }' \
	    '1:16: error: invalid assignment target'
check_error missing-if-paren 'int main() { if 1; return 0; }' \
	    "1:17: error: expect '('"
check_error missing-if-cond 'int main() { if () return 2; }' \
	    '1:18: error: expect expr'
check_error missing-if-rparen 'int main() { if (1 return 2; }' \
	    "1:20: error: expect ')'"
check_error missing-if-body 'int main() { if (1) }' \
	    '1:21: error: expect expr'
check_error missing-while-paren 'int main() { while 1; return 0; }' \
	    "1:20: error: expect '('"
check_error missing-while-cond 'int main() { while () return 0; }' \
	    '1:21: error: expect expr'
check_error missing-while-rparen 'int main() { while (1 return 0; }' \
	    "1:23: error: expect ')'"
check_error missing-while-body 'int main() { while (1) }' \
	    '1:24: error: expect expr'
check_error missing-for-paren 'int main() { for 1; return 0; }' \
	    "1:18: error: expect '('"
check_error missing-for-semi 'int main() { for (1) return 0; }' \
	    "1:20: error: expect ';'"
check_error missing-for-rparen 'int main() { for (1; 1; 1 return 0; }' \
	    "1:27: error: expect ')'"
check_error logical-and-operand 'int main() { return && 1; }' \
	    '1:21: error: expect expr'
check_error missing-logical-and-rhs 'int main() { return 1 &&; }' \
	    '1:25: error: expect expr'
check_error missing-logical-or-rhs 'int main() { return 1 ||; }' \
	    '1:25: error: expect expr'
check_error missing-bitand-rhs 'int main() { return 1 &; }' \
	    '1:24: error: expect expr'
check_error missing-bitor-rhs 'int main() { return 1 |; }' \
	    '1:24: error: expect expr'
check_error missing-bitxor-rhs 'int main() { return 1 ^; }' \
	    '1:24: error: expect expr'
check_error bitand-operand 'int main() { return & 1; }' \
	    '1:21: error: invalid address-of target'
check_error bitand-assign-literal 'int main() { 1 &= 2; return 0; }' \
	    '1:16: error: invalid assignment target'
check_error missing-do-while 'int main() { do return 0; }' \
	    "1:27: error: expect 'while'"
check_error missing-do-cond 'int main() { do return 0; while (); }' \
	    '1:34: error: expect expr'
check_error missing-do-rparen 'int main() { do return 0; while (1; }' \
	    "1:35: error: expect ')'"
check_error missing-do-semi 'int main() { do return 0; while (1) }' \
	    "1:36: error: expect ';'"
check_error missing-do-body 'int main() { do }' \
	    '1:17: error: expect expr'
check_error unterminated-comment 'int main() { /* comment' \
	    '1:14: error: unterminated comment'
check_error break-outside-loop 'int main() { break; }' \
	    '1:14: error: break statement not within loop or switch'
check_error continue-outside-loop 'int main() { continue; }' \
	    '1:14: error: continue statement not within loop'
check_error break-after-loop 'int main() { while (1) break; break; }' \
	    '1:31: error: break statement not within loop or switch'
check_error case-outside-switch 'int main() { case 1: ; }' \
	    '1:14: error: case label not within a switch statement'
check_error default-outside-switch 'int main() { default: ; }' \
	    '1:14: error: default label not within a switch statement'
check_error duplicate-case 'int main() { switch (1) { case 1: ; case 1: ; } }' \
	    '1:37: error: duplicate case value'
check_error duplicate-default \
	    'int main() { switch (1) { default: ; default: ; } }' \
	    '1:38: error: multiple default labels in one switch'
check_error case-not-constant \
	    'int main() { int a; switch (1) { case a: ; } }' \
	    '1:40: error: not an integer constant expression'
check_error decl-as-if-body 'int main() { if (1) int a = 1; return 0; }' \
	    '1:21: error: expect statement'
check_error decl-as-else-body 'int main() { if (1) ; else int b = 2; }' \
	    '1:28: error: expect statement'
check_error decl-as-while-body 'int main() { while (1) int a; }' \
	    '1:24: error: expect statement'
check_error decl-as-for-body 'int main() { for (;;) int a; }' \
	    '1:23: error: expect statement'
check_error decl-as-do-body 'int main() { do int a; while (1); }' \
	    '1:17: error: expect statement'
check_error decl-as-label-body 'int main() { L: int a; }' \
	    '1:17: error: expect statement'
check_error decl-as-case-body \
	    'int main() { switch (1) { case 1: int a; } }' \
	    '1:35: error: expect statement'
check_error redefinition \
	    'int foo() { return 0; } int foo() { return 1; } int main() { return 0; }' \
	    "1:29: error: redefinition of function 'foo'"
check_error call-undefined 'int main() { return foo(); }' \
	    "1:21: error: function 'foo' not declared"
check_error call-on-variable 'int main() { int a = 1; return a(); }' \
	    '1:32: error: called object is not a function'
check_error param-shadow 'int foo(int a) { int a = 42; return a; } int main() { return foo(24); }' \
	    "1:22: error: redefinition of parameter 'a'"
check_error too-many-args 'int foo(int a) { return a; } int main() { return foo(1, 2); }' \
	    "1:50: error: wrong number of arguments to function 'foo'"
check_error too-few-args 'int foo(int a) { return a; } int main() { return foo(); }' \
	    "1:50: error: wrong number of arguments to function 'foo'"
check_error missing-conditional-colon 'int main() { return 1 ? 2; }' \
	    "1:26: error: expect ':'"
check_error missing-conditional-then 'int main() { return 1 ? : 2; }' \
	    '1:25: error: expect expr'
check_error missing-conditional-else 'int main() { return 1 ? 2 : ; }' \
	    '1:29: error: expect expr'
check_error question-operand 'int main() { return ? 1; }' \
	    '1:21: error: expect expr'
check_error comma-assign 'int main() { int a; (a, a) = 1; return 0; }' \
	    '1:28: error: invalid assignment target'
check_error case-comma 'int main() { switch (1) { case 1, 2: ; } }' \
	    "1:33: error: expect ':'"
check_error missing-break-semi 'int main() { while (1) break }' \
	    "1:29: error: expect ';'"
check_error goto-undefined 'int main() { goto L; }' \
	    "1:14: error: label 'L' not defined"
check_error duplicate-label 'int main() { L: ; L: ; }' \
	    '1:19: error: duplicate label'
check_error duplicate-label-scope 'int main() { { L: ; } L: ; }' \
	    '1:23: error: duplicate label'
check_error goto-missing-name 'int main() { goto 1; }' \
	    '1:19: error: expect label name'
check_error goto-missing-semi 'int main() { L: ; goto L }' \
	    "1:25: error: expect ';'"
check_error octal-invalid-eight 'int main() { return 08; }' '1:21: error: invalid digit in octal integer literal'
check_error case-shift-negative 'int main() { switch (0) { case 1 << -1: return 1; default: return 0; } }' '1:39: error: invalid shift count in constant expression'
check_error case-shift-32 'int main() { switch (0) { case 1 << 32: return 1; default: return 0; } }' '1:39: error: invalid shift count in constant expression'
check_error case-overflow-mul 'int main() { switch (0) { case 2147483647 * 2147483647: return 1; default: return 0; } }' '1:55: error: integer overflow in constant expression'
check_error function-no-declaration 'int main() { return missing(); } int missing() { return 1; }' "1:21: error: function 'missing' not declared"
check_error conflicting-prototypes 'int f(int); int f(int x, int y); int main() { return 0; }' "1:17: error: conflicting declaration of function 'f'"
check_error void-with-arg 'int f(void); int main(void) { return f(1); } int f(void) { return 42; }' "1:38: error: wrong number of arguments to function 'f'"
check_error ptr-plus-ptr \
	    'int main() { int a; int *p; int *q; p = &a; q = &a; return p + q; }' \
	    '1:62: error: invalid operands to binary +'
check_error int-minus-ptr 'int main() { int a; int *p; p = &a; return 1 - p; }' \
	    '1:46: error: invalid operands to binary -'

printf 'All %d tests passed (%d execution, %d rejection).\n' "$((passed + rejected))" "$passed" "$rejected"
