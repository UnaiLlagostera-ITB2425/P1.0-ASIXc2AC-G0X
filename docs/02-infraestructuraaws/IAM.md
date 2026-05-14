# Crear cuenta y usuarios IAM
## Descripción de la tarea
Configurar usuarios y roles IAM para los distintos perfiles del proyecto: administradores de la plataforma y, opcionalmente, un usuario técnico con permisos para Terraform. La tarea estaba marcada como opcional con indicación de revisar la viabilidad en la cuenta de alumno.

## Limitaciones de AWS Academy Learner Lab
Tras revisar la documentación oficial y casos documentados de otros proyectos académicos, la conclusión es clara: las cuentas de AWS Academy Learner Lab tienen restricciones duras sobre IAM que no se pueden modificar.

Las limitaciones concretas son:
  - No es posible crear usuarios IAM nuevos. La cuenta voclabs no tiene permisos para ejecutar iam:CreateUser. Se trata de un límite impuesto por la plataforma que ni el alumno ni el instructor pueden cambiar.
  - No es posible crear roles IAM propios. En su lugar, la plataforma proporciona un rol predefinido llamado LabRole que debe usarse para todos los servicios que requieran un rol de ejecución (EC2, EKS, etc.).
  - No es posible crear ni adjuntar políticas IAM personalizadas. Las operaciones iam:CreatePolicy e iam:AttachUserPolicy están bloqueadas.
  - No es posible crear proveedores OIDC, lo que bloquea también la integración de herramientas que dependen de federación de identidad (como ciertos modos de autenticación de EKS o Terraform con OIDC).
  - El presupuesto es de $100 por cuenta y no se restaura. Si se agota, se pierde todo el trabajo.

## Impacto en el proyecto
| Funcionalidad prevista                     | ¿Viable? | Alternativa                                                   |
| ------------------------------------------ | -------- | ------------------------------------------------------------- |
| Crear usuario IAM para admins              | No       | Usar las credenciales de sesión del Learner Lab               |
| Crear usuario IAM para Terraform           | No       | Usar el rol LabRole con las credenciales temporales de sesión |
| Crear políticas IAM personalizadas         | No       | Usar políticas predefinidas de AWS adjuntas al LabRole        |
| Crear roles IAM propios                    | No       | Reutilizar el LabRole proporcionado por la plataforma         |
| Acceso programático a AWS (boto3, aws CLI) | Sí       | Usar las credenciales temporales de sesión del Learner Lab    |

## Decisión
La tarea "Crear cuenta y usuarios IAM" no es realizable en las cuentas AWS Academy Learner Lab debido a las restricciones duras de la plataforma.

La tarea queda **descartada**.