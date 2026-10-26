# Protocolo PR-02: Puerta forzada

**Versión:** 1.0 · octubre de 2026 · Documento ficticio para la demo "Del sensor al agente".

## Alcance

Aplica cuando un contacto magnético reporta la apertura de una puerta sin una credencial válida en cualquier zona de una Sede Demo, por ejemplo la bodega norte (Z-03). Lo usa el supervisor de turno del centro de operaciones.

El Agente de Operaciones solo clasifica, resume y propone una severidad. Ninguna acción física depende de él.

## Pasos

1. Verifica en la tarjeta la zona, la puerta asociada al dispositivo y la hora local del evento.
2. Revisa la cámara asignada a la zona y confirma si la puerta sigue abierta o ya está cerrada.
3. Consulta el registro de accesos de la zona para ver si hubo una apertura válida segundos antes.
4. Identifica señales de daño visibles en cámara, como marco doblado, vidrio roto o cerradura forzada.
5. Confirma si el evento ocurrió fuera del horario de 06:00 a 18:00. En ese caso la propuesta de severidad sube un nivel.
6. Registra en la tarjeta una observación corta con lo que viste y elige una decisión.

## Señales para la severidad

- Puerta abierta sin apertura válida y con daño visible: la propuesta puede subir un nivel.
- Apertura válida registrada segundos antes: la propuesta puede bajar un nivel.
- La propuesta nunca se aleja más de un nivel de la severidad inicial.

## Lo que decide una persona

Estas decisiones son siempre del supervisor y quedan registradas con quién, qué y cuándo:

- Escalar a autoridades o al equipo de respuesta de la sede.
- Abrir o bloquear la puerta o cualquier otro acceso.
- Enviar a alguien a revisar la puerta, confrontar o retener a una persona.
- Cerrar el incidente como falsa alarma.
- Cambiar este protocolo.
