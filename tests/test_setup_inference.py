"""make inference-up / check / down, con la nube simulada de test_setup_training."""

import pytest
from test_setup_training import Cloud

CHAMPION = [f"models/champion/{f}" for f in ("preprocessor.pkl", "model.pkl", "segment_map.json", "manifest.json")]


class Inference(Cloud):
    def up(self, *answers, **env):
        self.calls_file.write_text("")
        return self.run("up", "inference", answers=["y", *answers], **env)

    def check(self, **env):
        self.calls_file.write_text("")
        return self.run("check", "inference", **env)

    def down(self, *answers):
        self.calls_file.write_text("")
        return self.run("down", "inference", answers=answers)

    def schedule_on(self, *answers):
        self.calls_file.write_text("")
        return self.run("only", "inference", answers=answers, extra=["06_schedule_on"])

    def champion(self, files=CHAMPION):
        (self.state / "champion").write_text("".join(f"{f}\n" for f in files))

    def schedule(self, value=None):
        path = self.state / "schedule"
        if value:
            path.write_text(value + "\n")
        return path.read_text().strip()

    @property
    def applied(self):
        return [m.split("/infra/")[1].split()[0] for m in self.mutations if " apply " in m]


@pytest.fixture(scope="module")
def trained(tmp_path_factory):
    path = tmp_path_factory.mktemp("entrenado")
    cloud = Cloud(path)
    rc, out = cloud.up()
    assert rc == 0, out
    Inference.champion(cloud)
    return path


@pytest.fixture
def cloud(tmp_path, trained):
    return Inference(tmp_path, copy_of=trained)


@pytest.fixture
def ready(cloud):
    rc, out = cloud.up()
    assert rc == 0, out
    return cloud


def test_levanta_con_una_sola_confirmacion(cloud):
    rc, out = cloud.up()
    assert rc == 0, out
    assert out.count("[y/n]") == 1 and cloud.applied == ["inference"]
    assert cloud.schedule() == "DISABLED" and cloud.calls.count("variable set") == 4
    assert "pasos 4 y 5" in out and "docker" not in cloud.calls and "ec2" not in cloud.calls


def test_repetirlo_no_cambia_nada(ready):
    rc, _ = ready.up()
    assert rc == 0 and ready.mutations == []


def test_check(cloud):
    rc, _ = cloud.check()
    assert rc == 1 and cloud.mutations == []
    assert cloud.up()[0] == 0
    rc, out = cloud.check()
    assert rc == 0 and "todo listo" in out and cloud.mutations == []


@pytest.mark.parametrize("missing", CHAMPION)
def test_sin_champion_completo_se_detiene(cloud, missing):
    cloud.champion([f for f in CHAMPION if f != missing])
    rc, out = cloud.up()
    assert rc == 1 and "champion" in out and "promueve" in out and cloud.mutations == []


def test_sin_datos_se_detiene(cloud):
    (cloud.state / "lot").unlink()
    rc, out = cloud.up()
    assert rc == 1 and "make train-up" in out and cloud.mutations == []


def test_sin_las_variables_de_entrenamiento_se_detiene(cloud):
    (cloud.state / "variables").write_text("DATA_BUCKET\totro\n")
    rc, out = cloud.up()
    assert rc == 1 and "DATA_BUCKET" in out and cloud.mutations == []


def test_en_una_maquina_sin_entrenamiento_dice_que_correr(tmp_path):
    cloud = Inference(tmp_path)
    rc, out = cloud.up()
    assert rc == 1 and "make train-up" in out and cloud.mutations == []


def test_si_terraform_falla_se_retoma(cloud):
    cloud.have("fail.infra.inference")
    assert cloud.up()[0] == 1 and "variable set" not in cloud.calls
    (cloud.state / "fail.infra.inference").unlink()
    assert cloud.up()[0] == 0


def test_aplica_tambien_los_cambios_de_la_base_compartida(cloud):
    (cloud.state / "applied.infra.shared").unlink()
    # Sin la base no se puede leer el bucket: el paso 1 se detiene antes de tocar nada.
    assert cloud.up()[0] == 1 and cloud.mutations == []


@pytest.mark.parametrize("state", ["ENABLED", "DISABLED"])
def test_respeta_el_estado_del_scheduler(ready, state):
    ready.schedule(state)
    rc, _ = ready.up()
    assert rc == 0 and ready.schedule() == state and ready.mutations == []
    # También cuando hay otros cambios por aplicar.
    (ready.state / "applied.infra.inference").unlink()
    (ready.state / "plan").write_text("  # aws_iam_role.x will be updated in-place\nPlan: 0 to add\n")
    rc, _ = ready.up()
    assert rc == 0 and ready.schedule() == state and ready.applied == ["inference"]


def test_un_plan_que_borra_los_scores_se_detiene(ready):
    (ready.state / "applied.infra.inference").unlink()
    (ready.state / "plan").write_text("  # aws_s3_bucket.scores will be destroyed\nPlan: 0 to add\n")
    rc, out = ready.up("y")
    assert rc == 1 and "borraría datos" in out and ready.mutations == []


SCHEDULE_PLAN = "  # aws_scheduler_schedule.weekly will be updated in-place\nPlan: 0 to add, 1 to change\n"


def test_down_apaga_solo_el_scheduler(ready):
    ready.schedule("ENABLED")
    (ready.state / "plan").write_text(SCHEDULE_PLAN)
    rc, out = ready.down()
    assert rc == 0 and ready.schedule() == "DISABLED" and ready.applied == ["inference"] and "[y/n]" not in out


@pytest.mark.parametrize(("answer", "state"), [("n", "ENABLED"), ("y", "DISABLED")])
def test_down_pregunta_si_el_plan_cambia_otra_cosa(ready, answer, state):
    ready.schedule("ENABLED")
    (ready.state / "plan").write_text(SCHEDULE_PLAN + "  # aws_iam_role.x will be updated in-place\n")
    ready.down(answer)
    assert ready.schedule() == state


@pytest.mark.parametrize("state", ["DISABLED", None])
def test_down_sin_nada_que_apagar(cloud, state):
    if state:
        cloud.schedule(state)
    assert cloud.down()[0] == 0 and cloud.mutations == []


@pytest.mark.parametrize(("answer", "state"), [("y", "ENABLED"), ("n", "DISABLED")])
def test_encender_la_corrida_semanal_pregunta(ready, answer, state):
    (ready.state / "inference").write_text("Succeeded\n")
    (ready.state / "plan").write_text(SCHEDULE_PLAN)
    rc, out = ready.schedule_on(answer)
    assert "sin aprobación" in out and "2025-04-30" in out
    assert ready.schedule() == state and (rc == 0) == (answer == "y")


@pytest.mark.parametrize("last", [None, "", "Failed", "Executing"])
def test_no_enciende_si_la_ultima_corrida_no_termino_bien(ready, last):
    if last is not None:
        (ready.state / "inference").write_text(last + "\n")
    rc, _ = ready.schedule_on("y")
    assert rc == 1 and ready.schedule() == "DISABLED"


def test_encender_exige_que_el_scheduler_exista(cloud):
    rc, out = cloud.schedule_on("y")
    assert rc == 1 and "make inference-up" in out


def test_encender_dos_veces(ready):
    ready.schedule("ENABLED")
    rc, _ = ready.schedule_on()
    assert rc == 0 and ready.mutations == []


@pytest.mark.parametrize("step", ["", "../training/01_tools", "01_check;ls", "down"])
def test_un_paso_suelto_con_nombre_invalido(cloud, step):
    cloud.calls_file.write_text("")
    rc, _ = cloud.run("only", "inference", answers=["y"], extra=[step])
    assert rc == 2 and cloud.calls == ""
