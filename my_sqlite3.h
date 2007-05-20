#ifndef __INCLUDE_MY_SQLITE3_H__
#define __INCLUDE_MY_SQLITE3_H__

#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

//#include "ppport.h"

#include <sqlite3.h>

#ifndef DWORD
#define DWORD unsigned long
#endif

#define MYCF_TRANSACTION	1
#define MYCF_AUTOCOMMIT		2

#define MY_TYPE_CON		1
#define MY_TYPE_RES		2
#define MY_TYPE_STMT	3

typedef char **MY_ROW;

typedef struct st_my_rows {
	struct st_my_rows	*prev, *next;
	MY_ROW				data;
	DWORD				*lengths;
	char				*types;
} MY_ROWS;

typedef struct st_my_field {
	char				*name;
	DWORD				name_length;
} MY_FIELD;

typedef struct st_my_res {
	struct st_my_res	*prev, *next;
	MY_ROWS				*data_cursor;
	MY_ROWS				*current_row;
	struct st_my_con	*con;
	MY_FIELD			*fields;
	DWORD				numrows, numfields, rowpos, fieldpos;
	int					is_valid;
	struct st_my_stmt	*stmt;
} MY_RES;

typedef struct st_my_stmt {
	struct st_my_stmt	*prev, *next;
	struct st_my_con	*con;
	sqlite3_stmt		*stmt;
	DWORD				param_count;
	char				*param_types;
	MY_RES				*res;
} MY_STMT;

typedef struct st_my_con {
	struct st_my_con	*prev, *next;
	DWORD				tid;
	sqlite3				*con;
	char				*db;
	MY_RES				*firstres;
	MY_RES				*lastres;
	MY_STMT				*first_stmt;
	MY_STMT				*last_stmt;
	DWORD				my_flags;
	char				my_error[256];
} MY_CON;

typedef struct st_my_cxt {
	MY_CON				*lastcon;
	MY_CON				*firstcon;
	char				last_error[256];
	int					last_errno;
#ifdef USE_THREADS
	//perl_mutex			share_lock;
#endif
} my_cxt_t;

#define MY_CXT_KEY "PAB::DB::Driver::Sqlite3::_guts" XS_VERSION

START_MY_CXT

//DWORD my_crc32( const char *str, DWORD len );
unsigned long get_current_thread_id();
char *my_strcpy( char *dst, const char *src );
int my_stricmp( const char *cs, const char *ct );
char *my_stristr( const char *str1, const char *str2 );

void my_init();
void my_cleanup();
void my_session_cleanup();

long my_verify_linkid( long linkid );
int my_get_type( UV *ptr );
void my_set_error( const char *tpl, ... );

MY_CON *my_con_add( sqlite3 *con, DWORD tid );
void my_con_rem( MY_CON *con );
void my_con_free( MY_CON *con );
int my_con_exists( MY_CON *con );
MY_CON *my_con_find_by_tid( DWORD tid );
MY_CON *my_con_find_by_cid( DWORD cid );
void my_con_cleanup( MY_CON *con );

int my_callback( void *arg, int columns, char **data, char **names );

void my_result_free( MY_RES *res );
MY_RES *my_result_add( MY_CON *con );
void my_result_rem( MY_RES *res );
int my_result_exists( MY_RES *res );

MY_STMT *my_stmt_add( MY_CON *con, sqlite3_stmt *pStmt );
void my_stmt_rem( MY_STMT *stmt );
void my_stmt_free( MY_STMT *stmt );
int my_stmt_exists( UV ptr );
int my_stmt_bind_param( MY_STMT *stmt, int p_num, SV *val, char type );
int my_stmt_or_res( UV ptr );
int my_stmt_or_con( UV *ptr );

#endif
