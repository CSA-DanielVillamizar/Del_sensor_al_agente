# Protocolo PR-01: Movimiento en zona restringida

**Versión:** 1.0 · octubre de 2026 · Documento ficticio para la demo "Del sensor al agente".

## Alcance

Aplica cuando un sensor de movimiento reporta presencia en una zona restringida de una Sede Demo, como la sala de servidores (Z-01) o el cuarto eléctrico (Z-06). Lo usa el supervisor de turno del centro de operaciones.

El Agente de Operaciones solo clasifica, resume y propone una severidad. Ninguna acción física depende de él.

## Pasos

1. Verifica en la tarjeta la zona, la hora local y el número de repeticiones del evento.
2. Revisa la cámara asignada a la zona en el catálogo y busca una persona, un animal o un objeto en movimiento.
3. Consulta la agenda del turno para saber si hay mantenimiento o personal autorizado en esa zona a esa hora.
4. Compara con eventos recientes de la misma zona: varias repeticiones seguidas pesan más que un evento aislado.
5. Confirma si el evento ocurrió fuera del horario de 06:00 a 18:00. En ese caso la propuesta de severidad sube un nivel.
6. Registra en la tarjeta una observación corta con lo que viste y elige una decisión.

## Señales para la severidad

- Movimiento confirmado en cámara sin autorización: la propuesta puede subir un nivel.
- Mantenimiento programado que explica el movimiento: la propuesta puede bajar un nivel.
- La propuesta nunca se aleja más de un nivel de la severidad inicial.

## Lo que decide una persona

Estas decisiones son siempre del supervisor y quedan registradas con quién, qué y cuándo:

- Escalar a autoridades o al equipo de respuesta de la sede.
- Abrir o bloquear un acceso de la zona.
- Enviar a alguien a la zona, confrontar o retener a una persona.
- Cerrar el incidente como falsa alarma.
- Cambiar este protocolo.
