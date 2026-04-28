# Desplegar phpMyAdmin
## Descripción
Despliegue de phpMyAdmin como instancia temporal dentro del clúster K3s, expuesta mediante Ingress con restricción por IP para auditar las tablas de la base de datos centralizada en la EC2 DDBB (10.2.2.154). phpMyAdmin no se instala en la EC2 DDBB, sino que corre como pod en el clúster y se conecta a MariaDB a través del Service externo ya desplegado.

## Contexto de la arquitectura
| Elemento           | Valor                                             |
| ------------------ | ------------------------------------------------- |
| Pod                | Desplegado en clúster K3s — Master Erick          |
| Conecta a          | 10.2.2.154:3306 vía Service externo + VPC Peering |
| Expuesto en        | pma.meu-project.me                                |
| Acceso restringido | IP pública de Erick + IP pública de Manuel        |
| Carácter           | Temporal — solo para auditoría y validación       |

## Prerrequisitos
   - Clúster K3s operativo ✓
   - Service externo mariadb-external-service desplegado apuntando a 10.2.2.154:3306
   - Secret mariadb-credentials aplicado en el clúster
   - Ingress Controller Nginx activo en el clúster
   - IPs públicas de Erick y Manuel conocidas para el whitelist

## Estructura de ficheros
```sql
k8s/
└── phpmyadmin/
    ├── phpmyadmin-deployment.yaml
    ├── phpmyadmin-service.yaml
    └── phpmyadmin-ingress.yaml
```

## Manifiestos
   - phpmyadmin-deployment.yaml
     ```sql
     apiVersion: apps/v1
     kind: Deployment
     metadata:
       name: phpmyadmin
       namespace: default
     spec:
       replicas: 1
       selector:
         matchLabels:
           app: phpmyadmin
       template:
         metadata:
           labels:
             app: phpmyadmin
         spec:
           containers:
             - name: phpmyadmin
               image: phpmyadmin/phpmyadmin:5
               ports:
                 - containerPort: 80
               env:
                 - name: PMA_HOST
                   value: "10.2.2.154"
                 - name: PMA_PORT
                   value: "3306"
     ```

   - phpmyadmin-service.yaml
     ```sql
     apiVersion: v1
     kind: Service
     metadata:
       name: phpmyadmin-service
       namespace: default
     spec:
       selector:
         app: phpmyadmin
       ports:
         - port: 80
           targetPort: 80
     ```

   - phpmyadmin-ingress.yaml
     ```sql
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: phpmyadmin-ingress
      namespace: default
      annotations:
        nginx.ingress.kubernetes.io/whitelist-source-range: "54.163.235.144/32"
    spec:
      ingressClassName: nginx
      rules:
        - host: pma.meu-project.me
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: phpmyadmin-service
                    port:
                      number: 80
     ```

## Pasos de despliegue
```sql
kubectl apply -f k8s/phpmyadmin/phpmyadmin-deployment.yaml
kubectl apply -f k8s/phpmyadmin/phpmyadmin-service.yaml
kubectl apply -f k8s/phpmyadmin/phpmyadmin-ingress.yaml
```

- Verificar que el pod está corriendo:
```sql
kubectl get pods -l app=phpmyadmin
# → STATUS debe ser Running

kubectl get ingress phpmyadmin-ingress
# → Debe mostrar el host pma.meu-project.me
```

## Validación