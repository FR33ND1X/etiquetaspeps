# Etiquetador P.E.P.S.

Aplicación web estática para preparar etiquetas de producto y registrar ingresos a tienda. La autenticación, los perfiles y el historial compartido se gestionan en Supabase; GitHub Pages publica únicamente la interfaz.

## Acceso del personal

Cada persona inicia sesión con un usuario y una contraseña; no necesita correo. Para que Supabase Auth pueda validar la contraseña, cada cuenta usa internamente una dirección técnica terminada en `@accounts.peps.invalid`. No se envían correos a esa dirección. La interfaz nunca pide ni muestra esa dirección.

Los usuarios deben tener entre 3 y 32 caracteres: letras minúsculas, números, punto, guion o guion bajo. La contraseña inicial debe tener al menos 8 caracteres. La cuenta administradora crea los accesos desde **Usuarios** y comparte la contraseña por un medio seguro. Si alguien la olvida, una persona administradora puede restablecerla desde Supabase → Authentication → Users.

## Configuración de Supabase

1. Desactiva el registro público en **Authentication → Settings → Allow new users to sign up**.
2. En el editor SQL del proyecto, ejecuta [`supabase/schema.sql`](./supabase/schema.sql). Si ya había cuentas, el esquema asigna a cada perfil un usuario basado en la parte anterior al `@` de su correo anterior, resuelve duplicados con un sufijo y cambia el correo de autenticación a la dirección técnica. Las contraseñas y el historial existente se conservan.
3. Crea la cuenta inicial desde **Authentication → Users** con una dirección técnica, por ejemplo `administrador@accounts.peps.invalid`, una contraseña y el correo confirmado. El esquema creará el perfil con usuario `administrador`.
4. En el editor SQL, asigna el rol de administración con el usuario elegido:

   ```sql
   update public.profiles
   set role = 'admin'
   where username = 'administrador';
   ```

5. Publica la función de creación de cuentas. Con Supabase CLI, vincula el proyecto (`supabase link --project-ref TU_PROJECT_REF`) y ejecuta `supabase functions deploy create-user`.
6. Configura el secreto `ALLOWED_ORIGIN` con el origen de Pages, por ejemplo `https://usuario.github.io`, en **Edge Functions → Secrets** o con `supabase secrets set ALLOWED_ORIGIN=https://usuario.github.io`. Supabase proporciona las claves públicas y secretas a la función mediante variables del servidor. Nunca pongas una clave secreta en GitHub, `config.js` ni la página.

La opción de registro público debe permanecer desactivada; las cuentas nuevas se crean exclusivamente desde la función protegida, que verifica la sesión y el rol de administración. Las personas usuarias solo pueden cambiar su nombre visible. Para restablecer una contraseña, una persona administradora debe hacerlo desde Supabase Auth.

El historial puede consultarse por cualquier usuario autenticado, pero los usuarios no pueden actualizar ni borrar eventos. Los eventos se insertan mediante una función de base de datos que asigna el usuario, copia el nombre visible del actor y asigna la fecha del servidor. El rol `admin` tampoco permite editar el historial.

La interfaz registra el evento al solicitar la impresión, antes de abrir el diálogo del navegador; no puede detectar si la persona cancela ese diálogo. Los administradores con permisos directos sobre la base de datos pueden intervenir los datos: esta protección es de solo anexado frente a usuarios de la aplicación, no un almacenamiento WORM independiente.

## Publicar en GitHub Pages

1. En **Project Settings → API**, copia la URL del proyecto y la clave pública `anon`/`publishable`.
2. Completa [`config.js`](./config.js) con esos dos valores. Son visibles desde el navegador y no son secretos; las políticas RLS del esquema limitan el acceso. Nunca uses la clave `service_role` aquí.
3. Sube los archivos del proyecto y la carpeta `.github/workflows` a un repositorio de GitHub.
4. En el repositorio, abre **Settings → Pages** y selecciona **GitHub Actions** como origen de publicación.
5. Cada actualización de la rama `main` o `master` ejecutará el flujo de publicación. También puedes iniciarlo desde **Actions → Deploy to GitHub Pages → Run workflow**.
6. Al terminar, GitHub mostrará la dirección pública de la página. Configura su origen como `ALLOWED_ORIGIN` en Supabase y comparte la URL con el personal.

La primera carga requiere conexión a internet para utilizar Supabase y su biblioteca JavaScript. La aplicación no guarda contraseñas ni sustituye la autenticación del proveedor.
