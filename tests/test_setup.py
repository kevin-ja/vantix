"""Setup global (setup/): .env, encadenado de pasos y funciones comunes, con aws, gh y terraform simulados."""

import os
import pty
import select
import shutil
import stat
import subprocess
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SYSTEMS = {
    "training": ["SSO_START_URL", "SSO_REGION", "ACCOUNT_ID", "ROLE_NAME", "PROFILE", "GITHUB_REPO", "INGEST_DATE"],
    "inference": ["ACCOUNT_ID", "PROFILE", "GITHUB_REPO"],
    "monitoring": ["ACCOUNT_ID", "PROFILE", "GITHUB_REPO", "ALERT_EMAIL"],
}
ENV = {
    "SSO_START_URL": "https://portal.awsapps.com/start",
    "SSO_REGION": "us-east-1",
    "ACCOUNT_ID": "123456789012",
    "ROLE_NAME": "AdministratorAccess",
    "PROFILE": "prueba",
    "GITHUB_REPO": "ana/vantix",
    "INGEST_DATE": "2025-04-30",
    "ALERT_EMAIL": "ana@ejemplo.com",
}
AWS = r"""
echo "aws $*" >> "$CALLS"
case "$*" in
  "configure list-profiles") echo prueba ;;
  *get-caller-identity*) [ -z "$AWS_EXPIRED" ] || exit 255; echo "${AWS_ACCOUNT:-123456789012}" ;;
  *describe-instances*) echo "${EC2_STATE:-running}" ;;
esac
"""


class Sandbox:
    """Copia de setup/ con comandos simulados; CALLS guarda lo que se llamó."""

    def __init__(self, tmp):
        self.root = tmp / "repo"
        self.bin = tmp / "bin"
        self.calls_file = tmp / "calls"
        self.home = tmp / "home"
        shutil.copytree(REPO / "setup", self.root / "setup", ignore=shutil.ignore_patterns("logs"))
        self.bin.mkdir()
        self.home.mkdir()
        self.calls_file.write_text("")
        self.command("brew", "exit 0")  # si no, el setup agregaría el Homebrew real (y sus comandos) al PATH
        self.command("aws", AWS)
        self.command("gh", 'echo "gh $*" >> "$CALLS"')
        self.command("terraform", 'echo "terraform $*" >> "$CALLS"')
        self.command("curl", 'echo "curl $*" >> "$CALLS"; printf "%s" "${HTTP:-200}"')
        self.write_env()

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def write_env(self, extra="", **changes):
        values = {**ENV, **changes}
        lines = [f"{k}={v}" for k, v in values.items() if v is not None]
        (self.root / ".env").write_text("\n".join(lines) + "\n" + extra)

    def steps(self, system="training", **bodies):
        """Cada paso es 'review' | 'review/apply'; se listan en orden en system.sh."""
        for name, body in bodies.items():
            (self.root / "setup" / system / f"{name}.sh").write_text(
                f'# Paso: {name}\n. "$ROOT/setup/common/step.sh"\n{body}\nrun_step\n'
            )
        with (self.root / "setup" / system / "system.sh").open("a") as file:
            file.write(f'STEPS="{" ".join(bodies)}"\n')

    @property
    def calls(self):
        return self.calls_file.read_text()

    @property
    def logs(self):
        return "".join(p.read_text() for p in (self.root / "setup" / "logs").glob("*.log"))

    def environ(self, **env):
        base = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.home), "LANG": "C.UTF-8",
                "CALLS": str(self.calls_file), "HEALTH_INTERVAL": "0"}  # fmt: skip
        return {**base, **env}

    def run(self, action="check", system="training", answers=None, **env):
        """Sin answers corre sin terminal; con answers, en una terminal simulada que responde eso."""
        args = ["/bin/bash", str(self.root / "setup" / "run.sh"), action, system]
        if answers is None:
            done = subprocess.run(args, env=self.environ(**env), stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=60)  # fmt: skip
            return done.returncode, done.stdout + done.stderr
        main, worker = pty.openpty()
        process = subprocess.Popen(args, env=self.environ(**env), stdin=worker, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)  # fmt: skip
        os.close(worker)
        os.write(main, "".join(f"{a}\n" for a in answers).encode())
        output, limit = b"", time.monotonic() + 60
        while time.monotonic() < limit:
            if select.select([process.stdout], [], [], 1)[0]:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                output += chunk
        os.close(main)
        return process.wait(timeout=10), output.decode()

    def common(self, body, answers=None, mode="up", **env):
        """Corre código dentro de un paso."""
        self.steps(only=f'review() {{ todo "x"; }}\nverify() {{ :; }}\napply() {{\n{body}\n}}' if mode == "up"
                   else f"review() {{\n{body}\n}}")  # fmt: skip
        return self.run(mode, answers=None if mode == "check" else ["y", *(answers or [])], **env)


@pytest.fixture
def box(tmp_path):
    return Sandbox(tmp_path)


DONE = 'review() { echo "REVIEW $0" >> "$CALLS"; }'


def marker(name, fails=False):
    """Paso que falta hasta que se aplica (deja un archivo)."""
    action = "die roto" if fails else f'echo "APPLY {name}" >> "$CALLS"; touch "$ROOT/{name}.done"'
    return f'review() {{ [ -f "$ROOT/{name}.done" ] || todo "falta {name}"; }}\napply() {{ {action}; }}'


# --- .env ---------------------------------------------------------------------------------------


@pytest.mark.parametrize("system", SYSTEMS)
@pytest.mark.parametrize("action", ["check", "up", "down"])
def test_sin_env_se_detiene(box, system, action):
    (box.root / ".env").unlink()
    rc, out = box.run(action, system, answers=["y"])
    assert rc == 1 and "cp .env.example .env" in out
    assert box.calls == ""


@pytest.mark.parametrize(("system", "key"), [(s, k) for s, keys in SYSTEMS.items() for k in keys])
def test_una_variable_que_falta_detiene_antes_de_tocar_nada(box, system, key):
    box.steps(system, one=marker("one"))
    for value in (None, "", "<completar>"):
        box.write_env(**{key: value})
        rc, out = box.run("up", system, answers=["y"])
        assert rc == 1 and key in out and "falta" in out
    assert box.calls == ""


def test_lista_todos_los_problemas_juntos(box):
    box.steps(one=marker("one"))
    box.write_env(SSO_START_URL=None, ACCOUNT_ID="12", GITHUB_REPO="sinbarra", INGEST_DATE="2025-02-30")
    rc, out = box.run("up", answers=["y"])
    assert rc == 1 and "(4)" in out
    for key in ("SSO_START_URL", "ACCOUNT_ID", "GITHUB_REPO", "INGEST_DATE"):
        assert key in out
    assert box.calls == ""


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("SSO_START_URL", "http://portal.awsapps.com/start"),
        ("SSO_REGION", "virginia"),
        ("ACCOUNT_ID", "123456789012 # comentario"),
        ("ROLE_NAME", "con espacio"),
        ("PROFILE", "a;b"),
        ("GITHUB_REPO", "https://github.com/ana/vantix"),
        ("INGEST_DATE", "2023-02-29"),
        ("INGEST_DATE", "2025-13-01"),
    ],
)
def test_formato_invalido(box, key, value):
    box.steps(one=DONE)
    box.write_env(**{key: value})
    rc, out = box.run()
    assert rc == 1 and key in out and box.calls == ""


def test_correo_invalido(box):
    box.steps("monitoring", one=DONE)
    box.write_env(ALERT_EMAIL="ana")
    assert box.run("check", "monitoring")[0] == 1


@pytest.mark.parametrize("value", ["2024-02-29", "2025-08-09", "2000-02-29"])
def test_fechas_validas(box, value):
    box.steps(one=DONE)
    box.write_env(INGEST_DATE=value)
    assert box.run()[0] == 0


@pytest.mark.parametrize(
    "key", ["AWS_SECRET_ACCESS_KEY", "AWS_ACCESS_KEY_ID", "GITHUB_TOKEN", "GH_TOKEN", "MI_PASSWORD"]
)
def test_credenciales_se_rechazan_sin_mostrarlas(box, key):
    box.steps(one=DONE)
    box.write_env(extra=f"{key}=valor-secreto\n")
    rc, out = box.run()
    assert rc == 1 and key in out and "valor-secreto" not in out and box.calls == ""


def test_claves_desconocidas_repetidas_y_lineas_raras(box):
    box.steps(one=DONE)
    box.write_env(extra="PROFLE=x\nPROFILE=otro\nsin igual\n")
    rc, out = box.run()
    assert rc == 1 and "PROFLE" in out and "repetida" in out and "línea" in out


def test_env_no_se_ejecuta(box):
    box.steps(one=DONE)
    box.write_env(extra="$(touch $HOME/ejecutado)\n", PROFILE="$(touch $HOME/ejecutado)")
    assert box.run()[0] == 1
    assert not (box.home / "ejecutado").exists()


def test_env_acepta_comillas_espacios_y_crlf(box):
    box.steps(one='review() { echo "[$PROFILE][$GITHUB_REPO][$ROLE_NAME]" >> "$CALLS"; }')
    box.write_env(PROFILE='"prueba"', GITHUB_REPO="'ana/vantix'", ROLE_NAME=" Admin \r")
    assert box.run()[0] == 0
    assert "[prueba][ana/vantix][Admin]" in box.calls


def test_env_manda_sobre_la_terminal(box):
    box.steps(one='review() { echo "[$PROFILE]" >> "$CALLS"; }')
    assert box.run(PROFILE="otro")[0] == 0
    assert "[prueba]" in box.calls


def test_una_variable_de_la_terminal_no_reemplaza_a_la_que_falta(box):
    box.steps(one=DONE)
    box.write_env(PROFILE=None)
    assert box.run(PROFILE="otro")[0] == 1


def test_plantilla_tiene_todas_las_claves_y_esta_incompleta(box):
    template = (REPO / ".env.example").read_text()
    for key in ENV:
        assert f"\n{key}=" in template
    box.steps(one=DONE)
    (box.root / ".env").write_text(template)
    rc, out = box.run()
    assert rc == 1 and "no se reconoce" not in out and "línea" not in out


# --- encadenado ---------------------------------------------------------------------------------


def test_up_corre_en_orden_y_repetirlo_no_cambia_nada(box):
    box.steps(a=marker("a"), b=marker("b"), c=marker("c"))
    rc, out = box.run("up", answers=["y"])
    assert rc == 0, out
    assert box.calls.split("\n")[:3] == ["APPLY a", "APPLY b", "APPLY c"]
    box.calls_file.write_text("")
    assert box.run("up", answers=["y"])[0] == 0
    assert "APPLY" not in box.calls


def test_up_se_detiene_en_el_paso_que_falla_y_despues_continua(box):
    box.steps(a=marker("a"), b=marker("b", fails=True), c=marker("c"))
    rc, out = box.run("up", answers=["y"])
    assert rc == 1 and "paso 2 de 3" in out and "make train-up" in out and "setup/logs/" in out
    assert "APPLY c" not in box.calls
    (box.root / "b.done").touch()
    box.calls_file.write_text("")
    assert box.run("up", answers=["y"])[0] == 0
    assert "APPLY a" not in box.calls and "APPLY c" in box.calls


def test_up_falla_si_el_paso_no_queda_como_se_esperaba(box):
    box.steps(a='review() { todo "falta"; }\napply() { :; }')
    assert box.run("up", answers=["y"])[0] == 1


def test_up_con_n_no_cambia_nada(box):
    box.steps(a=marker("a"))
    rc, out = box.run("up", answers=["n"])
    assert rc == 1 and "No se cambió nada" in out and "APPLY" not in box.calls


@pytest.mark.parametrize("action", ["up", "down"])
def test_sin_terminal_no_cambia_nada(box, action):
    box.steps(a=marker("a"))
    assert box.run(action)[0] == 1
    assert "APPLY" not in box.calls


def test_check_no_pregunta_ni_aplica_y_revisa_todo(box):
    box.steps(a=marker("a"), b='review() { confirm "¿?" && echo SI >> "$CALLS"; die "sin sesión"; }', c=marker("c"))
    rc, out = box.run(answers=["y", "y"])  # aunque haya una terminal que respondería que sí
    assert rc == 1 and "3 de 3" in out and "falta c" in out
    assert "APPLY" not in box.calls and "SI" not in box.calls


def test_check_con_todo_listo(box):
    box.steps(a=DONE, b=DONE)
    rc, out = box.run()
    assert rc == 0 and "todo listo" in out


def test_down_corre_solo_su_paso(box):
    box.steps(a=marker("a"))
    (box.root / "setup/training/down.sh").write_text(
        '# Paso: Apagar\n. "$ROOT/setup/common/step.sh"\nreview() { todo x; }\nverify() { :; }\n'
        'apply() { echo DOWN >> "$CALLS"; }\nrun_step\n'
    )
    assert box.run("down", answers=[])[0] == 0
    assert "DOWN" in box.calls and "APPLY" not in box.calls


def test_un_paso_suelto_explica_como_correrlo(box):
    box.steps(a=DONE)
    done = subprocess.run(["/bin/bash", "-c", f'. "{box.root}/setup/common/step.sh"'], env=box.environ(),
                          capture_output=True, text=True)  # fmt: skip
    assert done.returncode == 1 and "make train-up" in done.stderr


@pytest.mark.parametrize("args", [[], ["up"], ["up", "otro"], ["borrar", "training"], ["up", "training", "x"]])
def test_argumentos_invalidos(box, args):
    done = subprocess.run(["/bin/bash", str(box.root / "setup/run.sh"), *args], env=box.environ(), capture_output=True)
    assert done.returncode == 2 and box.calls == ""


# --- AWS ----------------------------------------------------------------------------------------


def test_cuenta_equivocada_se_detiene(box):
    rc, out = box.common('check_aws; echo SIGUE >> "$CALLS"', AWS_ACCOUNT="999999999999")
    assert rc == 1 and "999999999999" in out and "SIGUE" not in box.calls


def test_cuenta_correcta_sigue_y_las_llaves_de_la_terminal_no_cuentan(box):
    rc, _ = box.common('check_aws; echo "[$AWS_PROFILE][$AWS_SECRET_ACCESS_KEY]" >> "$CALLS"',
                       AWS_SECRET_ACCESS_KEY="x", AWS_PROFILE="otro")  # fmt: skip
    assert rc == 0 and "[prueba][]" in box.calls


def test_check_no_inicia_sesion(box):
    rc, out = box.common("check_aws", mode="check", AWS_EXPIRED="1")
    assert rc == 1 and "aws sso login" in out and "sso login" not in box.calls


def test_perfil_inexistente(box):
    box.write_env(PROFILE="nuevo")
    assert box.common("check_aws")[0] == 1


# --- Terraform ----------------------------------------------------------------------------------


def plan(box, text):
    """terraform show devuelve este plan."""
    box.command("terraform", f"""
echo "terraform $*" >> "$CALLS"
case "$*" in *" show "*) cat <<'PLAN'
{text}
PLAN
;; esac""")


APPLY = "show_plan infra/shared; approve_plan infra/shared; tf_apply infra/shared"


@pytest.mark.parametrize("verb", ["must be replaced", "will be destroyed", "is tainted, so must be replaced"])
@pytest.mark.parametrize("name", ["aws_s3_bucket.scores", "aws_ebs_volume.data", "module.x.aws_s3_bucket.data"])
def test_plan_que_borra_datos_se_detiene_sin_preguntar(box, name, verb):
    plan(box, f"  # {name} {verb}\nPlan: 0 to add")
    rc, out = box.common(APPLY, answers=["y"])
    assert rc == 1 and "borraría datos" in out and "apply" not in box.calls


@pytest.mark.parametrize(("answer", "applied"), [("y", True), ("n", False)])
def test_plan_que_reemplaza_pregunta(box, answer, applied):
    plan(box, "  # aws_instance.mlflow must be replaced\nPlan: 1 to add, 0 to change, 1 to destroy.")
    rc, out = box.common(APPLY, answers=[answer])
    assert "ATENCIÓN" in out and (rc == 0) == applied and (" apply " in box.calls) == applied


@pytest.mark.parametrize("change", ["will be created", "will be updated in-place"])
def test_plan_que_crea_o_actualiza_no_pregunta(box, change):
    plan(box, f"  # aws_iam_role.x {change}\nPlan: 1 to add, 0 to change, 0 to destroy.")
    rc, out = box.common(APPLY)
    assert rc == 0 and "aws_iam_role.x" in out and " apply " in box.calls


def test_borrar_un_recurso_asociado_al_bucket_no_es_borrar_datos_pero_pregunta(box):
    plan(box, "  # aws_s3_bucket_policy.scores will be destroyed\nPlan: 0 to add, 0 to change, 1 to destroy.")
    rc, out = box.common(APPLY, answers=["n"])
    assert rc == 1 and "ATENCIÓN" in out


def test_error_de_terraform_se_muestra_y_detiene(box):
    box.command("terraform", 'case "$*" in *" apply "*) echo "Error: no autorizado"; exit 1;; esac')
    rc, out = box.common("tf_apply infra/shared")
    assert rc == 1 and "no autorizado" in out


def test_apply_muestra_el_avance(box):
    box.command("terraform", """case "$*" in *" apply "*)
echo "aws_s3_bucket.data: Creating..."
echo "aws_s3_bucket.data: Still creating... [10s elapsed]"
echo "aws_s3_bucket.data: Creation complete after 2s [id=abc]"
echo "Apply complete! Resources: 1 added, 0 changed, 0 destroyed.";; esac""")
    rc, out = box.common("tf_apply infra/shared")
    assert rc == 0 and "Creation complete after 2s" in out and "id=abc" not in out and "Still" not in out
    assert "Still creating" in box.logs


@pytest.mark.parametrize(("mode", "lock"), [("up", "true"), ("check", "false")])
def test_check_no_bloquea_el_estado(box, mode, lock):
    box.common("tf_plan infra/shared", mode=mode)
    assert f"-lock={lock}" in box.calls


# --- GitHub -------------------------------------------------------------------------------------

VARIABLES = r"""
SPECS=("A|m|a|^.+$" "B|m|b|^.+$")
printf 'A\t1\nB\t2\n' > "$WORK/values"
read_current
compare
save_pending
"""


@pytest.mark.parametrize(("scope", "flag"), [("env", "--env production"), ("repo", None)])
def test_variables_que_faltan_se_crean_sin_preguntar(box, scope, flag):
    rc, out = box.common(f"SCOPE={scope}\n{VARIABLES}")
    assert rc == 0 and "¿Cambiarlas?" not in out
    saved = [line for line in box.calls.splitlines() if "variable set" in line]
    assert len(saved) == 2 and all(("--env production" in line) == bool(flag) for line in saved)


@pytest.mark.parametrize(("answer", "saved"), [("y", 1), ("n", 0)])
def test_cambiar_una_variable_existente_pregunta(box, answer, saved):
    box.command("gh", 'echo "gh $*" >> "$CALLS"; case "$*" in *"variable list"*) printf "A\\tviejo\\nB\\t2\\n";; esac')
    rc, out = box.common(VARIABLES, answers=[answer])
    assert "viejo" in out and (rc == 0) == bool(saved)
    assert box.calls.count("variable set") == saved


@pytest.mark.parametrize("sub", ["environment:production", "ref:refs/heads/main"])
@pytest.mark.parametrize(("trusted", "passes"), [("repo:ana/vantix", True), ("repo:otro/vantix", False)])
def test_confianza_entre_aws_y_el_repo(box, sub, trusted, passes):
    box.command("gh", 'echo "-"')
    box.command("aws", f"""echo '{{"sub": "{trusted}:{sub}"}}'""")
    rc, _ = box.common(f'TRUST_ROLE=R; TRUST_SUB={sub}; SOURCE="make train-up"\n'
                       "printf 'R\\tarn:aws:iam::123456789012:role/x\\n' > \"$WORK/values\"; check_trust")  # fmt: skip
    assert (rc == 0) == passes


# --- servidores ---------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("state", "starts", "passes"),
    [("running", 0, True), ("pending", 0, True), ("stopped", 1, True), ("stopping", 1, True), ("terminated", 0, False)],
)
def test_encender(box, state, starts, passes):
    rc, out = box.common("ensure_running i-1", EC2_STATE=state)
    assert (rc == 0) == passes and box.calls.count("start-instances") == starts
    assert ("este setup la encendió" in out) == bool(starts)
    assert ("wait instance-stopped" in box.calls) == (state == "stopping")


@pytest.mark.parametrize(("state", "stops"), [("running", 1), ("stopped", 0), ("stopping", 0)])
def test_apagar(box, state, stops):
    rc, _ = box.common("ensure_stopped i-1", EC2_STATE=state)
    assert rc == 0 and box.calls.count("stop-instances") == stops and "terminate" not in box.calls


@pytest.mark.parametrize(("http", "passes"), [("200", True), ("504", False)])
def test_espera_de_respuesta(box, http, passes):
    rc, _ = box.common("wait_health https://x/health 0 || die no", HTTP=http)
    assert (rc == 0) == passes


# --- registro -----------------------------------------------------------------------------------


def test_el_registro_guarda_el_detalle_sin_credenciales(box):
    rc, out = box.common('spin "Probando" echo "detalle ghp_abcDEF123 AKIAABCDEFGHIJKLMNOP"\n'
                         "spin Otra printf '%s' 'db_password = \"clave123\"'")  # fmt: skip
    assert rc == 0 and "detalle" not in out
    assert "detalle" in box.logs
    for secret in ("ghp_abcDEF123", "AKIAABCDEFGHIJKLMNOP", "clave123"):
        assert secret not in box.logs
    for path in (box.root / "setup/logs").glob("*.log"):
        assert path.stat().st_mode & 0o077 == 0


def test_sintaxis_de_bash():
    for path in (REPO / "setup").rglob("*.sh"):
        subprocess.run(["/bin/bash", "-n", str(path)], check=True)
