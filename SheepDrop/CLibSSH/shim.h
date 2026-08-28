/* SheepDrop CLibSSH umbrella. WITH_SERVER must be defined BEFORE sftp.h so the
 * server-side SFTP API (sftp_server_new/init, sftp_reply_*, sftp_handle_*) is
 * visible — it lives behind #ifdef WITH_SERVER in libssh's sftp.h. */
#define WITH_SERVER 1
#include <libssh/libssh.h>
#include <libssh/server.h>
#include <libssh/sftp.h>
#include <libssh/callbacks.h>
