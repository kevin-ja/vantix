# MLflow server · Arquitectura

> Servidor de tracking de MLflow propio, desechable y barato, en AWS. Es la **condición cero** (semilla) de un futuro
> repo independiente para montar servidores de MLflow de distintas capacidades (equipos chicos, medianos y grandes).
> Esta versión cubre el caso **equipo chico** (ver §5).

## 1. Idea central: servidor desechable, estado en S3

- El servidor (EC2) no guarda nada que no esté en S3. Se puede apagar, destruir o reemplazar sin perder información.
- **Fuente de verdad: S3.**
  - Bases SQLite (registry + usuarios) → replicadas por **Litestream** en segundos.
  - Artefactos → escritos directo en S3 por el servidor (proxy).
- Al arrancar, la EC2 restaura las bases desde S3 y luego levanta MLflow.

```
clientes (SageMaker, GitHub Actions, navegador)
   │ HTTPS + basic auth
   ▼
CloudFront (*.cloudfront.net, sin caché) ──HTTP:5000──▶ Elastic IP ──▶ EC2 t3.small (Docker Compose)
                                                                        ├─ restore-*  (Litestream, al arrancar)
                                                                        ├─ mlflow     (basic auth, proxy de artefactos)
                                                                        └─ replicate  (Litestream, continuo)
                                                                               │
                                                     S3: <bucket>/registry/ (bases)  ·  <bucket>/artifacts/
```

## 2. Componentes

| Pieza | Recurso | Detalle |
|---|---|---|
| Servidor | EC2 `t3.small`, Amazon Linux 2023 | Docker Compose: `restore-registry`, `restore-auth`, `mlflow`, `replicate` (`compose.yml`) |
| Imagen | ECR (tags inmutables = commit de `mlflow_server/`) | `docker/Dockerfile`: MLflow 3.18.0 + basic auth |
| Registry y usuarios | SQLite en el disco de la EC2 + **réplica continua en S3** (Litestream) | `litestream.yml`; 7 días de historial (restauración a un punto anterior) |
| Artefactos | S3 (`artifacts/`) | `--serve-artifacts`: los clientes suben y bajan a través del servidor, sin credenciales de S3 |
| HTTPS | CloudFront con certificado por defecto | Sin dominio propio. Sin caché (TTL 0). Reenvía `Authorization` |
| Red | VPC por defecto. Al puerto 5000 solo entra CloudFront (prefix list administrada) | Sin SSH: administración por SSM (`make shell`, `make logs`) |
| IP fija | Elastic IP | El origen de CloudFront no cambia al apagar o reemplazar la EC2 |
| Autenticación | Basic auth de MLflow; contraseña de `admin` en SSM Parameter Store (SecureString) | La genera Terraform; se usa al crear la base de usuarios |
| IaC | Terraform (`infra/`), estado en S3 | La EC2 se **reemplaza** si cambia la imagen o la configuración |

## 3. Reproducibilidad (100 % fijado)

| Qué | Cómo |
|---|---|
| Python (servidor y tests) | `requirements.in` → lock completo con **hashes** (`make lock`); `pip install --require-hashes` |
| Imágenes Docker | tag + **digest `@sha256`** |
| Terraform y providers | versión exacta + `.terraform.lock.hcl` con hashes |
| Sistema operativo | **AMI fija** (`ami_id`); AL2023 bloquea los repos a la release de la AMI |
| Docker Compose | versión fija, verificada por **sha256** |
| Imagen desplegada | tag inmutable = commit de git de `mlflow_server/` |

## 4. Operación (todo por `make`, ver `README.md`)

- **Encender / apagar:** `make start` / `make stop`. El estado no depende de la EC2.
- **Actualizar:** commit → `make up`. Construye la imagen nueva y reemplaza la EC2, que restaura el estado desde S3.
- **Probar:**
  - `make smoke`: auth, run, artefacto y registry;
  - `make recreate-test`: destruye la EC2 y comprueba que todo vuelve.
- **Bajar el cómputo:** `make down`. Conserva bucket, imagen y contraseña, así que `make up` recupera todo.

## 5. Alcance y limitaciones

**Capacidad objetivo: equipo chico.** Pocos usuarios, una corrida de entrenamiento a la vez, más promociones ocasionales.

- **SQLite admite un solo escritor a la vez.** Para VANTIX alcanza, porque hay un entrenamiento a la vez más una
  promoción. No serviría para un equipo grande escribiendo en paralelo; en ese caso habría que volver a Postgres,
  por ejemplo en RDS.
- **Una sola instancia, una sola AZ.** Sin alta disponibilidad: mientras la EC2 se reemplaza o arranca (unos minutos),
  el servidor no responde. Los clientes deben reintentar o esperar.
- **Pérdida máxima de datos (RPO): ~1 s** de escrituras, si la EC2 muere de golpe (`sync-interval` de Litestream).
- **Tramo CloudFront → EC2 en HTTP.** El navegador y los clientes hablan HTTPS con CloudFront, pero de CloudFront al
  origen va HTTP, con el header `Authorization` incluido. Mejora futura: dominio propio + TLS en el origen, o CloudFront
  VPC origin con la EC2 en subred privada.
- **Basic auth.** Usuario y contraseña, sin SSO ni tokens con vencimiento.

### Hacia el repo independiente (futuro)

| Capacidad | Backend | Cómputo | Alta disponibilidad |
|---|---|---|---|
| Chico (esta versión) | SQLite + Litestream → S3 | 1 EC2 | No |
| Mediano | Postgres (RDS) | 1 EC2 o ECS | Parcial |
| Grande | Aurora Postgres | ECS/EKS con varias réplicas + ALB | Sí |

## 6. Costo aproximado (us-east-1)

| Uso | Costo/mes |
|---|---|
| Encendido 24/7 | ≈ USD 20 |
| 8 h × lunes a viernes | ≈ USD 9 |
| Apagado (IP + disco) | ≈ USD 5 |
