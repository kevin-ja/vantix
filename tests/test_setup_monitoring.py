"""make monitoring-up / check / down, con la nube simulada de test_setup_training."""

import pytest
from test_setup_inference import CHAMPION, Inference
from test_setup_training import CLOUD, Cloud


class Monitoring(Cloud):
    def up(self, *answers, **env):
        self.calls_file.write_text("")
        return self.run("up", "monitoring", answers=["y", *answers], **env)

    def check(self, **env):
        self.calls_file.write_text("")
        return self.run("check", "monitoring", **env)

    def down(self, *answers):
        self.calls_file.write_text("")
        return self.run("down", "monitoring", answers=answers)

    def sample(self, *answers, **env):
        self.calls_file.write_text("")
        return self.run("only", "monitoring", answers=answers, extra=["06_sample_batch"], **env)

    def ec2(self, value=None):
        path = self.state / "ec2.monitoring"
        if value:
            path.write_text(value + "\n")
        return path.read_text().strip()

    def server(self):
        """Estado de la EC2 de MLflow: el monitoreo no debe tocarla."""
        return (self.state / "ec2").read_text().strip()

    @property
    def tfvars(self):
        return self.root / "monitorization/infra/terraform.tfvars"


@pytest.fixture(scope="module")
def trained(tmp_path_factory):
    path = tmp_path_factory.mktemp("entrenado")
    cloud = Cloud(path)
    rc, out = cloud.up()
    assert rc == 0, out
    Inference.champion(cloud)
    (path / "state/ec2").write_text("stopped\n")
    return path


@pytest.fixture
def cloud(tmp_path, trained):
    return Monitoring(tmp_path, copy_of=trained)


@pytest.fixture
def ready(cloud):
    rc, out = cloud.up()
    assert rc == 0, out
    return cloud


def test_levanta_con_una_sola_confirmacion(cloud):
    rc, out = cloud.up()
    assert rc == 0, out
    assert out.count("[y/n]") == 1 and cloud.ec2() == "running" and cloud.server() == "stopped"
    assert cloud.tfvars.read_text() == (
        'github_repo = "ana/vantix"\nalert_email = "ana@ejemplo.com"\ndata_bucket = "vantix-123456789012-data"\n'
    )
    order = ["buildx build", "monitorization/infra apply -input=false -no-color /", "variable set"]
    positions = [cloud.calls.index(step) for step in order]
    assert positions == sorted(positions)
    saved = [line for line in cloud.calls.splitlines() if "variable set" in line]
    assert len(saved) == 3 and not any("--env" in line for line in saved)
    assert "revisa spam" in out and "pasos 5 y 7" in out and "clave-ecr" not in out + cloud.logs


def test_repetirlo_no_cambia_nada(ready):
    rc, _ = ready.up()
    assert rc == 0 and ready.mutations == []


def test_check(cloud):
    rc, _ = cloud.check()
    assert rc == 1 and cloud.mutations == [] and "alert_email" not in cloud.tfvars.read_text()
    assert cloud.up()[0] == 0
    rc, out = cloud.check()
    assert rc == 0 and "todo listo" in out and cloud.mutations == []


def test_no_hace_falta_docker_ni_imagen_si_ya_hay_una_vigente(ready):
    (ready.state / "image.vantix-monitoring").unlink()
    (ready.state / "docker").unlink()
    rc, _ = ready.up()
    assert rc == 0 and ready.mutations == []


def test_si_terraform_falla_se_retoma_sin_reconstruir(cloud):
    cloud.have("fail.monitorization.infra")
    assert cloud.up()[0] == 1
    (cloud.state / "fail.monitorization.infra").unlink()
    assert cloud.up()[0] == 0
    assert cloud.up()[0] == 0 and cloud.mutations == []


@pytest.mark.parametrize("missing", CHAMPION)
def test_sin_champion_completo_se_detiene(cloud, missing):
    Inference.champion(cloud, [f for f in CHAMPION if f != missing])
    rc, out = cloud.up()
    assert rc == 1 and "promueve" in out and cloud.mutations == []


@pytest.mark.parametrize(
    ("variable", "value", "message"),
    [
        ("STUB_VPC", "None", "create-default-vpc"),
        ("STUB_SUBNET", "None", "create-default-subnet"),
        ("STUB_AMI", "deregistered", "ami_id"),
    ],
)
def test_red_o_imagen_base_que_faltan(cloud, variable, value, message):
    rc, out = cloud.up(**{variable: value})
    assert rc == 1 and message in out and cloud.mutations == []


def test_sin_autorizar_o_sin_oidc(cloud):
    text = cloud.tfvars.read_text()
    cloud.tfvars.unlink()
    assert cloud.up()[0] == 1 and cloud.mutations == []
    cloud.tfvars.write_text(text)
    (cloud.state / "oidc.own").unlink()
    rc, out = cloud.up()
    assert rc == 1 and "OIDC" in out and cloud.mutations == []


def test_codigo_sin_commitear(cloud):
    (cloud.root / "pipelines/common/config.py").write_text("otro\n")
    rc, out = cloud.up()
    assert rc == 1 and "sin commitear" in out and cloud.mutations == []


def test_cambiar_el_correo_conserva_lo_demas(ready):
    ready.write_env(ALERT_EMAIL="otra@ejemplo.com")
    assert ready.up()[0] == 0
    text = ready.tfvars.read_text()
    assert 'alert_email = "otra@ejemplo.com"' in text and "ana@ejemplo.com" not in text and "github_repo" in text
    assert list(ready.tfvars.parent.glob("anterior.*.tfvars"))


@pytest.mark.parametrize(
    ("status", "text"), [("Success", "confirmado"), ("Pending", "spam"), ("Failed", "verify-email")]
)
def test_estado_del_correo(ready, status, text):
    rc, out = ready.check(STUB_EMAIL=status)
    assert rc == 0 and text in out


@pytest.mark.parametrize("name", ["aws_ebs_volume.data", "aws_s3_bucket.monitoring"])
def test_un_plan_que_borra_datos_se_detiene(ready, name):
    (ready.state / "applied.monitorization.infra").unlink()
    (ready.state / "plan").write_text(f"  # {name} must be replaced\nPlan: 1 to add\n")
    rc, out = ready.up("y")
    assert rc == 1 and "borraría datos" in out and ready.mutations == []


@pytest.mark.parametrize(("answer", "applies"), [("y", 1), ("n", 0)])
def test_reemplazar_la_ec2_pregunta(ready, answer, applies):
    (ready.state / "applied.monitorization.infra").unlink()
    (ready.state / "plan").write_text("  # aws_instance.server must be replaced\nPlan: 1 to add\n")
    rc, out = ready.up(answer)
    assert "ATENCIÓN" in out and len(ready.mutations) == applies and (rc == 0) == bool(applies)


def test_grafana_que_no_responde(cloud):
    cloud.command("curl", CLOUD["curl"].replace("printf 200", "printf 504"))
    path = cloud.root / "setup/monitoring/03_infra.sh"
    path.write_text(path.read_text().replace("HEALTH_WAIT=420", "HEALTH_WAIT=0"))
    rc, out = cloud.up()
    assert rc == 1 and "Grafana no respondió" in out and "paso 3 de 4" in out


def test_down_apaga_solo_el_monitoreo_y_up_lo_enciende(ready):
    (ready.state / "ec2").write_text("running\n")
    rc, _ = ready.down()
    assert rc == 0 and len(ready.mutations) == 1 and "stop-instances" in ready.calls and "i-2" in ready.mutations[0]
    assert ready.server() == "running"
    ready.ec2("stopped")
    rc, out = ready.up()
    assert rc == 0 and len(ready.mutations) == 1 and "este setup la encendió" in out


@pytest.mark.parametrize(("answer", "stops"), [("y", 1), ("n", 0)])
def test_down_con_una_corrida_en_curso_pregunta(ready, answer, stops):
    (ready.state / "monitoring").write_text("1234-abcd\n")
    rc, out = ready.down(answer)
    assert "en curso" in out and (rc == 0) == bool(stops) and ready.calls.count("stop-instances") == stops


@pytest.mark.parametrize("state", ["stopped", None])
def test_down_sin_nada_que_apagar(cloud, state):
    if state:
        cloud.ec2(state)
    assert cloud.down()[0] == 0 and cloud.mutations == []


@pytest.mark.parametrize(("kind", "lot"), [("estable", "2025-06-30"), ("degradado", "2025-07-31")])
def test_lote_de_prueba_pregunta(cloud, kind, lot):
    rc, out = cloud.sample("n", TIPO=kind)
    assert rc == 1 and "ÚLTIMO" in out and cloud.mutations == []
    rc, out = cloud.sample("y", TIPO=kind)
    assert rc == 0 and f"--ingest-date {lot}" in cloud.calls and f"ingest_date = {lot}" in out
    rc, out = cloud.sample(TIPO=kind)
    assert rc == 0 and "ya existe" in out and cloud.mutations == []


def test_lote_de_prueba_con_otra_fecha(cloud):
    rc, out = cloud.sample("y", TIPO="estable", LOTE="2025-03-31")
    assert rc == 0 and "--ingest-date 2025-03-31" in cloud.calls and "ÚLTIMO" not in out


@pytest.mark.parametrize("env", [{}, {"TIPO": "otro"}, {"TIPO": "estable", "LOTE": "2025-02-30"}])
def test_lote_de_prueba_mal_indicado(cloud, env):
    rc, _ = cloud.sample("y", **env)
    assert rc == 1 and cloud.mutations == []
