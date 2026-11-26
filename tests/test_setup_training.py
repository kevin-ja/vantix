"""make train-up / check / down desde cero, con una nube simulada que recuerda lo que se creó."""

import hashlib
import re
import shutil
import subprocess

import pytest
from test_setup import REPO, Sandbox

ACCOUNT = "123456789012"
DATA = "datos de prueba\n"
SHA = hashlib.sha256(DATA.encode()).hexdigest()

CLOUD = {
    "aws": r"""
echo "aws $*" >> "$CALLS"
ec2="$S/ec2"; id=i-1
case "$*" in *i-2*|*vantix-monitoring-server*) ec2="$S/ec2.monitoring"; id=i-2 ;; esac
missing() { echo "An error occurred ($1)" >&2; exit 254; }
case "$1 $2" in
  "--version ") echo "aws-cli/2.36.0" ;;
  "configure list-profiles") cat "$S/profiles" 2>/dev/null ;;
  "configure get") cat "$S/profile.$3" 2>/dev/null ;;
  "configure set") echo "$4" > "$S/profile.$3"; echo prueba > "$S/profiles" ;;
  "sso login") touch "$S/session" ;;
  "sts get-caller-identity")
    [ -f "$S/session" ] || missing ExpiredToken
    account="$(cat "$S/account" 2>/dev/null || echo 123456789012)"
    case "$*" in *Arn*) printf '%s\tarn:aws:sts::%s:assumed-role/AWSReservedSSO_Admin_x/ana\n' "$account" "$account" ;;
                 *) echo "$account" ;; esac ;;
  "organizations describe-organization") echo 111111111111 ;;
  "service-quotas list-service-quotas") printf 'L-ABC\t%s\n' "${STUB_QUOTA:-1.0}" ;;
  "service-quotas list-requested-service-quota-change-history-by-quota") printf '%s\n' "$STUB_QUOTA_REQUESTS" ;;
  "service-quotas request-service-quota-increase") echo PENDING ;;
  "s3api head-bucket")
    [ -z "$STUB_FORBIDDEN" ] || missing 403
    [ -f "$S/bucket.$4" ] || missing "404) Not Found" ;;
  "s3api create-bucket") touch "$S/bucket.$4" ;;
  "s3api put-bucket-versioning") touch "$S/versioning" ;;
  "s3api get-bucket-versioning") [ -f "$S/versioning" ] && echo Enabled || echo None ;;
  "s3api put-public-access-block") touch "$S/private" ;;
  "s3api get-public-access-block")
    [ -f "$S/private" ] || missing NoSuchPublicAccessBlockConfiguration
    printf 'True\tTrue\tTrue\tTrue\n' ;;
  "s3api head-object")
    case "$*" in
      *tfstate*) [ -f "$S/applied.mlflow_server.infra" ] || missing 404 ;;
      *sha256*) cat "$S/lot" ;;
      *) [ -f "$S/lot" ] || missing 404; echo 16 ;;
    esac ;;
  "s3api list-objects-v2")
    case "$*" in *models/champion/*) tr '\n' '\t' < "$S/champion" 2>/dev/null || echo None; exit ;; esac
    [ -f "$S/lot" ] || { echo None; exit; }
    case "$*" in *data.parquet*) echo "raw/ingest_date=2025-04-30/data.parquet" ;;
                 *) sed 's#.*#raw/ingest_date=&/data.parquet#' "$S/lots" ;; esac ;;
  "ecr describe-images") [ -f "$S/image.${6%%-backend}" ] || missing ImageNotFoundException ;;
  "ecr get-login-password") echo clave-ecr ;;
  "ec2 describe-instances")
    case "$*" in *InstanceId*) [ -f "$ec2" ] && echo "$id" || echo None ;; *) cat "$ec2" ;; esac ;;
  "ec2 start-instances") echo running > "$ec2" ;;
  "ec2 stop-instances") echo stopping > "$ec2" ;;
  "ec2 describe-vpcs") echo "${STUB_VPC:-vpc-1}" ;;
  "ec2 describe-subnets") echo "${STUB_SUBNET:-subnet-1}" ;;
  "ec2 describe-images") echo "${STUB_AMI:-available}" ;;
  "ssm get-parameter") [ -f "$S/pointer" ] || missing ParameterNotFound; cat "$S/pointer" ;;
  "ssm list-command-invocations") cat "$S/monitoring" 2>/dev/null; true ;;
  "ses get-identity-verification-attributes") echo "${STUB_EMAIL:-Pending}" ;;
  "ec2 wait") ;;
  "iam get-open-id-connect-provider") [ -f "$S/oidc" ] || [ -f "$S/oidc.own" ] || missing NoSuchEntity ;;
  "iam get-role")
    case "$*" in *github_run_role*) sub="ref:refs/heads/main" ;; *) sub="environment:production" ;; esac
    echo "{\"sub\": \"repo:ana/vantix:$sub\"}" ;;
  "s3 cp") printf '{\n  "model_version": "3",\n  "k": 5\n}\n' > "${!#}" ;;
  "scheduler get-schedule") [ -f "$S/schedule" ] || missing ResourceNotFoundException; cat "$S/schedule" ;;
  "sagemaker list-pipeline-executions")
    case "$*" in
      *vantix-inference*) [ -f "$S/inference" ] || missing ResourceNotFound; cat "$S/inference" ;;
      *) cat "$S/training" 2>/dev/null; true ;;
    esac ;;
  *) echo "aws sin simular: $*" >&2; exit 99 ;;
esac
""",
    "terraform": r"""
if [ "$1" = version ]; then echo "Terraform v1.15.8"; exit; fi
echo "terraform $*" >> "$CALLS"
module="$(printf '%s' "${1#-chdir=$ROOT/}" | tr / .)"
case "$2" in
  init) ;;
  plan)
    rm -f "$S/wanted"
    case "$*" in
      *schedule_enabled=true*) echo ENABLED > "$S/wanted" ;;
      *schedule_enabled=false*) echo DISABLED > "$S/wanted" ;;
    esac
    [ -f "$S/applied.$module" ] || exit 2
    [ ! -f "$S/wanted" ] || cmp -s "$S/wanted" "$S/schedule" || exit 2
    exit 0 ;;
  show)
    cat "$S/plan" 2>/dev/null && exit
    if [ "$module" = infra.shared ]; then echo "  # aws_iam_openid_connect_provider.github will be created"
    else echo "  # aws_iam_role.x will be created"; fi
    echo "Plan: 1 to add, 0 to change, 0 to destroy." ;;
  apply)
    [ ! -f "$S/fail.$module" ] || { echo "Error: se cortó"; exit 1; }
    case "$*" in *-target=*) ;; *)
      touch "$S/applied.$module"
      case "$module" in
        mlflow_server.infra) [ -f "$S/image.vantix-mlflow" ] || exit 1; echo running > "$S/ec2" ;;
        monitorization.infra) [ -f "$S/image.vantix-monitoring" ] || exit 1
          echo running > "$S/ec2.monitoring"; echo abc1234 > "$S/pointer" ;;
        infra.inference) cp "$S/wanted" "$S/schedule"; touch "$S/bucket.vantix-$ACCOUNT_ID-scores" ;;
        infra.shared) touch "$S/oidc.own" "$S/bucket.vantix-$ACCOUNT_ID-data" ;;
      esac ;;
    esac
    echo "Apply complete!" ;;
  output)
    case "$4:$module" in
      ecr_repository_url:monitorization*) echo "1.dkr.ecr/vantix-monitoring"; exit ;;
      ecr_repository_url:*) echo "1.dkr.ecr/vantix-mlflow"; exit ;;
    esac
    [ -f "$S/applied.$module" ] || { echo "No outputs found" >&2; exit 1; }
    case "$4" in
      tracking_uri|mlflow_tracking_uri) echo https://mlflow.example.com ;;
      grafana_url) echo https://grafana.example.com ;;
      instance_id) case "$module" in monitorization*) echo i-2 ;; *) echo i-1 ;; esac ;;
      data_bucket) echo "vantix-$ACCOUNT_ID-data" ;;
      scores_bucket) echo "vantix-$ACCOUNT_ID-scores" ;;
      mlflow_password_param) echo /vantix-mlflow/admin-password ;;
      *role_arn) echo "arn:aws:iam::$ACCOUNT_ID:role/$4" ;;
    esac ;;
esac
""",
    "gh": r"""
echo "gh $*" >> "$CALLS"
case "$*" in api*) [ -f "$S/gh" ] || { echo "HTTP 401" >&2; exit 4; } ;; esac
case "$*" in
  "--version") echo "gh version 2.96.0" ;;
  "auth login"*) touch "$S/gh" ;;
  *"--method PUT repos/ana/vantix/environments/production"*) touch "$S/environment" ;;
  "api"*" user "*login,*) printf 'ana\t7\n' ;;
  "api"*" user "*) echo ana ;;
  "api"*environments/production*reviewers*)
    [ -f "$S/environment" ] || { echo "HTTP 404" >&2; exit 1; }
    case "$*" in *wait_timer:*) echo '{}' ;;
                 *) printf 'production\t%s\t%s\tfalse\t0\tfalse\n' "${STUB_REVIEWERS:-ana}" "${STUB_ENV_ME:-true}" ;;
    esac ;;
  "api"*environments/production*) [ -f "$S/environment" ] && echo production || { echo "HTTP 404" >&2; exit 1; } ;;
  "api"*customization/sub*use_default*) printf 'true\tfalse\t-\n' ;;
  "api"*customization/sub*) echo - ;;
  "api"*repos/ana/vantix*) printf 'ana/vantix\ttrue\n' ;;
  "variable list"*DATA_BUCKET*) awk -F '\t' '$1 == "DATA_BUCKET" { print $2 }' "$S/variables" ;;
  "variable list"*) cat "$S/variables" 2>/dev/null; true ;;
  "variable set"*) while [ $# -gt 0 ]; do case "$1" in set) name="$2" ;; --body) body="$2" ;; esac; shift; done
                   printf '%s\t%s\n' "$name" "$body" >> "$S/variables" ;;
esac
""",
    "docker": r"""
echo "docker $*" >> "$CALLS"
case "$1 $2" in
  "--version ") echo "Docker version 27.4.0" ;;
  "info ") [ -f "$S/docker" ] ;;
  "buildx version") ;;
  "login "*) cat > /dev/null ;;
  "buildx build")
    case "$*" in *vantix-monitoring*) touch "$S/image.vantix-monitoring" ;; *) touch "$S/image.vantix-mlflow" ;; esac
    echo "#5 [1/2] FROM python" ;;
esac
""",
    "curl": r"""
echo "curl $*" >> "$CALLS"
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; https://*) url="$1" ;; esac; shift; done
[ -z "$STUB_OFFLINE" ] || exit 6
case "$url" in
  *.sha256) echo "$STUB_SHA  data.parquet" > "$out" ;;
  *data.parquet) printf '%s\n' "${STUB_DOWNLOAD:-datos de prueba}" > "$out" ;;
  */api/health) [ "$(cat "$S/ec2.monitoring" 2>/dev/null)" = running ] && printf 200 || printf 504 ;;
  */health) [ "$(cat "$S/ec2" 2>/dev/null)" = running ] && printf 200 || printf 504 ;;
esac
""",
    "uv": r"""
echo "uv $*" >> "$CALLS"
case "$*" in
  "--version") echo "uv 0.11" ;;
  "venv "*) mkdir -p "$ROOT/.venv/bin"; touch "$ROOT/.venv/pyvenv.cfg"; cp "$BIN/fakepython" "$ROOT/.venv/bin/python" ;;
  *--dry-run*) [ -f "$S/libs" ] && echo "Would make no changes" ;;
  "pip install"*) touch "$S/libs" ;;
esac
""",
    "fakepython": r"""
case "$1" in
  *check_data.py) echo "✔ DATA OK: 1 rows" ;;
  *upload_raw.py) echo "python $*" >> "$CALLS"; echo "$STUB_SHA" > "$S/lot"; echo "$7" >> "$S/lots"; echo "1 filas" ;;
  *make_synthetic_batches.py)
    for date in "$7" "$9"; do mkdir -p "$5/ingest_date=$date"; touch "$5/ingest_date=$date/data.parquet"; done ;;
  -c) case "$2" in *version_info*) echo "${STUB_PYTHON:-3.11.9}" ;; esac ;;
esac
""",
    "open": 'echo "open $*" >> "$CALLS"; touch "$S/docker"',
    "uname": 'echo "${STUB_SYSTEM_NAME:-Darwin}"',
    "xcode-select": "exit 0",
    "make": 'echo "GNU Make 3.81"',
    "sleep": "exit 0",
}
MUTATIONS = re.compile(
    r"aws (configure set|sso login|s3api (create|put)|ec2 (start|stop)|service-quotas request)|terraform .* apply|"
    r"gh (auth login|variable set|api .*--method PUT)|docker (buildx build|login)|"
    r"uv (venv|pip install --python)|open|python"
)


class Cloud(Sandbox):
    def __init__(self, tmp, copy_of=None):
        self.state = tmp / "state"
        if copy_of:
            shutil.copytree(copy_of, tmp, dirs_exist_ok=True)
            self.root, self.bin, self.home, self.calls_file = tmp / "repo", tmp / "bin", tmp / "home", tmp / "calls"
            return
        super().__init__(tmp)
        self.state.mkdir()
        for name, body in CLOUD.items():
            self.command(name, body)
        folders = ("mlflow_server/docker", "infra/shared", "infra/training", "infra/inference", "monitorization/infra")
        for path in (*folders, "scripts"):
            (self.root / path).mkdir(parents=True)
        (self.root / "mlflow_server/docker/Dockerfile").write_text("FROM x\n")
        for path in ("monitorization/docker/Dockerfile", "monitorization/src/job.py", "pipelines/common/config.py"):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text("x\n")
        shutil.copy(REPO / "monitorization/infra/variables.tf", self.root / "monitorization/infra")
        (self.root / "requirements-dev.txt").write_text("boto3\n")
        shutil.copy(REPO / ".gitignore", self.root)
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("-c", "user.name=ana", "-c", "user.email=ana@ejemplo.com", "commit", "-qm", "inicio")
        self.git("remote", "add", "origin", "https://github.com/ana/vantix.git")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True, text=True).stdout

    def environ(self, **env):
        return super().environ(**{"S": str(self.state), "BIN": str(self.bin), "STUB_SHA": SHA, **env})

    def up(self, *answers, **env):
        self.calls_file.write_text("")
        return self.run("up", "training", answers=["y", *answers], **env)

    def check(self, **env):
        self.calls_file.write_text("")
        return self.run("check", "training", **env)

    def have(self, *names):
        for name in names:
            (self.state / name).touch()

    @property
    def mutations(self):
        return [line for line in self.calls.splitlines() if MUTATIONS.match(line)]


@pytest.fixture
def cloud(tmp_path):
    return Cloud(tmp_path)


@pytest.fixture(scope="module")
def finished(tmp_path_factory):
    """Todo levantado, una sola vez; cada prueba usa una copia."""
    path = tmp_path_factory.mktemp("listo")
    rc, out = Cloud(path).up()
    assert rc == 0, out
    return path


@pytest.fixture
def ready(tmp_path, finished):
    return Cloud(tmp_path, copy_of=finished)


def test_desde_cero_con_una_sola_confirmacion(cloud):
    rc, out = cloud.up()
    assert rc == 0, out
    assert out.count("[y/n]") == 1
    order = ["uv venv", "gh auth login", "s3api create-bucket", "docker buildx build", "-chdir=%s/infra/shared apply",
             "-chdir=%s/infra/training apply", "upload_raw.py", "variable set"]  # fmt: skip
    positions = [cloud.calls.index(step.replace("%s", str(cloud.root))) for step in ["sso login", *order]]
    assert positions == sorted(positions)
    assert cloud.calls.count("variable set") == 6
    assert (cloud.root / "data/data.parquet").read_text() == DATA
    for path in ("infra/shared", "monitorization/infra"):
        assert (cloud.root / path / "terraform.tfvars").read_text() == 'github_repo = "ana/vantix"\n'
    assert "pasos 12 y 13" in out and "make train-down" in out
    assert "clave-ecr" not in out + cloud.logs


def test_repetirlo_no_cambia_nada(ready):
    rc, out = ready.up()
    assert rc == 0 and ready.mutations == [], ready.mutations
    assert out.count("[y/n]") == 1


def test_check_desde_cero_no_cambia_nada(cloud):
    rc, out = cloud.check()
    assert rc == 1 and "pendiente" in out and cloud.mutations == []
    assert not (cloud.root / "data").exists() and not (cloud.root / ".venv").exists()


def test_check_con_todo_listo(ready):
    rc, out = ready.check()
    assert rc == 0 and "todo listo" in out and ready.mutations == []


@pytest.mark.parametrize("module", ["mlflow_server.infra", "infra.shared", "infra.training"])
def test_si_terraform_falla_se_retoma_donde_quedo(cloud, module):
    cloud.have(f"fail.{module}")
    rc, out = cloud.up()
    assert rc == 1 and "se cortó" in out and "variable set" not in cloud.calls
    (cloud.state / f"fail.{module}").unlink()
    rc, out = cloud.up()
    assert rc == 0 and "sso login" not in cloud.calls and "create-bucket" not in cloud.calls


def test_down_apaga_y_up_solo_enciende(ready):
    ready.calls_file.write_text("")
    rc, out = ready.run("down", "training", answers=[])
    assert rc == 0 and [m.split(" --")[0] for m in ready.mutations] == ["aws ec2 stop-instances"]
    (ready.state / "ec2").write_text("stopped\n")
    assert ready.check()[0] == 1
    rc, out = ready.up()
    assert rc == 0 and [m.split(" --")[0] for m in ready.mutations] == ["aws ec2 start-instances"]
    assert "este setup la encendió" in out


@pytest.mark.parametrize(("answer", "stops"), [("y", 1), ("n", 0)])
def test_down_con_un_entrenamiento_en_curso_pregunta(ready, answer, stops):
    (ready.state / "training").write_text("arn:aws:sagemaker:us-east-1:1:pipeline/x\n")
    rc, out = ready.run("down", "training", answers=[answer])
    assert "en curso" in out and (rc == 0) == bool(stops) and ready.calls.count("stop-instances") == stops


def test_down_repetido_o_sin_servidor(cloud):
    (cloud.state / "profiles").write_text("prueba\n")
    cloud.have("session")
    assert cloud.run("down", "training", answers=[])[0] == 0
    (cloud.state / "ec2").write_text("stopped\n")
    assert cloud.run("down", "training", answers=[])[0] == 0
    assert "stop-instances" not in cloud.calls


# --- herramientas -------------------------------------------------------------------------------


def old_gh(cloud):
    cloud.command("gh", 'echo "gh version 2.10.0"')
    cloud.command("brew", 'echo "brew $*" >> "$CALLS"')


def test_instalar_pregunta_antes(cloud):
    old_gh(cloud)
    rc, out = cloud.up("n")
    assert rc == 1 and "GitHub CLI" in out and "No se instaló nada" in out
    assert "brew upgrade" not in cloud.calls and "brew install" not in cloud.calls and cloud.mutations == []


def test_instala_solo_lo_que_falta(cloud):
    old_gh(cloud)
    rc, _ = cloud.up("y")
    assert "brew upgrade gh" in cloud.calls and "awscli" not in cloud.calls
    assert rc == 1  # el gh simulado sigue viejo: no se da por listo


def test_sin_macos_no_instala(cloud):
    old_gh(cloud)
    rc, out = cloud.up("y", STUB_SYSTEM_NAME="Linux")
    assert rc == 1 and "a mano" in out and "brew upgrade" not in cloud.calls


# --- AWS ----------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("key", "value"), [("sso_account_id", "999999999999"), ("sso_role_name", "Lector"), ("aws_access_key_id", "AKIAX")]
)
def test_un_perfil_existente_distinto_no_se_toca(ready, key, value):
    (ready.state / f"profile.{key}").write_text(value + "\n")
    rc, _ = ready.up()
    assert rc == 1 and ready.mutations == []


def test_sesion_de_otra_cuenta(ready):
    (ready.state / "account").write_text("999999999999\n")
    rc, out = ready.up()
    assert rc == 1 and "999999999999" in out and ready.mutations == []


def test_sesion_vencida_se_renueva(ready):
    (ready.state / "session").unlink()
    rc, _ = ready.up()
    assert rc == 0 and ready.mutations == ["aws sso login --profile prueba"]


def test_conserva_el_resto_de_la_configuracion_de_aws(cloud):
    config = cloud.home / ".aws/config"
    config.parent.mkdir()
    config.write_text("[profile otro]\nregion = eu-west-1\n")
    assert cloud.up()[0] == 0
    text = config.read_text()
    assert text.startswith("[profile otro]\nregion = eu-west-1\n") and "[sso-session prueba]" in text
    assert len(list(config.parent.glob("config.anterior.*"))) == 1


def test_bucket_del_estado_ajeno(ready):
    rc, out = ready.up(STUB_FORBIDDEN="1")
    assert rc == 1 and "existe en otra cuenta" in out and ready.mutations == []


@pytest.mark.parametrize(
    ("flag", "call"), [("versioning", "put-bucket-versioning"), ("private", "put-public-access-block")]
)
def test_corrige_el_bucket_del_estado(ready, flag, call):
    (ready.state / flag).unlink()
    assert ready.up()[0] == 0
    assert len(ready.mutations) == 1 and call in ready.mutations[0]


# --- Python y dataset ---------------------------------------------------------------------------


@pytest.mark.parametrize(("answer", "kept"), [("n", True), ("y", False)])
def test_borrar_el_entorno_pregunta(ready, answer, kept):
    (ready.root / ".venv/propio").touch()
    rc, out = ready.up(answer, STUB_PYTHON="3.9.1")
    assert rc == 1 and "BORRAR" in out
    assert (ready.root / ".venv/propio").exists() == kept


def test_descarga_danada_no_reemplaza_lo_que_habia(ready):
    data = ready.root / "data/data.parquet"
    data.write_text("otra version")
    rc, out = ready.up(STUB_DOWNLOAD="roto")
    assert rc == 1 and "dañada" in out and data.read_text() == "otra version"
    assert not list(data.parent.glob("*.part.*"))


def test_reemplaza_el_dataset_guardando_el_anterior(ready):
    data = ready.root / "data/data.parquet"
    data.write_text("otra version")
    assert ready.up()[0] == 0
    assert data.read_text() == DATA and [p.read_text() for p in data.parent.glob("*.anterior.*")] == ["otra version"]


def test_sin_conexion_sirve_un_archivo_completo(ready):
    rc, out = ready.check(STUB_OFFLINE="1")
    assert "se usa ese" in out


def test_un_lote_distinto_no_se_sobrescribe(ready):
    (ready.state / "lot").write_text("f" * 64 + "\n")
    rc, out = ready.up()
    assert rc == 1 and "no se sobrescribe" in out and ready.mutations == []


# --- GitHub -------------------------------------------------------------------------------------


def test_token_en_la_terminal_impide_iniciar_sesion(cloud):
    rc, out = cloud.up(GH_TOKEN="x")
    assert rc == 1 and "unset GH_TOKEN" in out and "auth login" not in cloud.calls


def test_tfvars_conserva_lo_demas(cloud):
    path = cloud.root / "monitorization/infra/terraform.tfvars"
    path.write_text('alert_email = "a@b.co"\ngithub_repo = "viejo/repo"\n')
    assert cloud.up()[0] == 0
    assert path.read_text() == 'alert_email = "a@b.co"\ngithub_repo = "ana/vantix"\n'
    assert len(list(path.parent.glob("anterior.*.tfvars"))) == 1


def test_avisa_si_la_carpeta_es_de_otro_repo(cloud):
    cloud.git("remote", "set-url", "origin", "git@github.com:otra/vantix.git")
    rc, out = cloud.up()
    assert rc == 0 and "se clonó de otra/vantix" in out


@pytest.mark.parametrize(("answer", "puts"), [("y", 1), ("n", 0)])
def test_cambiar_un_environment_existente_pregunta(ready, answer, puts):
    rc, out = ready.up(answer, STUB_REVIEWERS="otra", STUB_ENV_ME="false")
    assert "hoy: otra" in out and ready.calls.count("--method PUT") == puts and rc == 1


@pytest.mark.parametrize(("answer", "requests"), [("y", 1), ("n", 0)])
def test_cuota_baja_pregunta_y_no_impide_seguir(cloud, answer, requests):
    rc, out = cloud.up(answer, STUB_QUOTA="0.0")
    assert rc == 0 and "no entrenar" in out and cloud.calls.count("request-service-quota-increase") == requests


def test_cuota_ya_pedida_no_pregunta(ready):
    rc, out = ready.up(STUB_QUOTA="0.0", STUB_QUOTA_REQUESTS="PENDING\t1.0")
    assert rc == 0 and out.count("[y/n]") == 1 and ready.mutations == []


# --- infraestructura ----------------------------------------------------------------------------


def test_mlflow_con_cambios_sin_commitear(ready):
    (ready.root / "mlflow_server/docker/Dockerfile").write_text("FROM y\n")
    rc, out = ready.up()
    assert rc == 1 and "sin commitear" in out and ready.mutations == []


def test_proveedor_oidc_ajeno(cloud):
    cloud.have("oidc")
    rc, out = cloud.up()
    assert rc == 1 and "cuenta dedicada" in out and f"-chdir={cloud.root}/infra/shared apply" not in cloud.calls


def test_plan_que_borra_el_bucket_de_datos_se_detiene(ready):
    (ready.state / "applied.infra.shared").unlink()
    (ready.state / "plan").write_text("  # aws_s3_bucket.data must be replaced\nPlan: 1 to add\n")
    rc, out = ready.up("y")
    assert rc == 1 and "borraría datos" in out and ready.mutations == []


def test_mlflow_que_no_responde(cloud):
    cloud.command("curl", CLOUD["curl"].replace("printf 200", "printf 504"))
    path = cloud.root / "setup/training/08_mlflow.sh"
    path.write_text(path.read_text().replace("HEALTH_WAIT=300", "HEALTH_WAIT=0"))
    rc, out = cloud.up()
    assert rc == 1 and "no respondió" in out and "paso 8 de 11" in out


def test_imagen_nueva_sin_docker(ready):
    (ready.state / "image.vantix-mlflow").unlink()
    (ready.state / "docker").unlink()
    ready.command("open", "exit 1")
    rc, out = ready.up()
    assert rc == 1 and "Docker" in out and "buildx build" not in ready.calls
