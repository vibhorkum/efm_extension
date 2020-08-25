#include "postgres.h"

#include "fmgr.h"
#include "catalog/pg_type.h"
#include "miscadmin.h"
#include "postmaster/syslogger.h"
#include "funcapi.h"
#include "access/hash.h"
#include "utils/builtins.h"
#include "utils/guc.h"

#include <stdio.h>
#include <unistd.h>

#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

/* execute some generic command and return status */
PG_FUNCTION_INFO_V1(efm_cluster_status);
PG_FUNCTION_INFO_V1(efm_allow_node);
PG_FUNCTION_INFO_V1(efm_disallow_node);
PG_FUNCTION_INFO_V1(efm_set_priority);
PG_FUNCTION_INFO_V1(efm_failover);
PG_FUNCTION_INFO_V1(efm_switchover);
PG_FUNCTION_INFO_V1(efm_resume_monitoring);
PG_FUNCTION_INFO_V1(efm_list_properties);

/* GUC declaration */
char *efm_path_command = NULL;
char *efm_sudo = NULL;
char *efm_cluster_name = NULL;
char *efm_properties_file_loc = NULL;

/* function declaration */
void _PG_init(void);
static void requireSuperuser(void);
static void check_efm_cluster_name_sudo(char *clustername, char *efm_sudo);
static void check_efm_properties_file(char *efm_properties);


/*
 * check if cluster name is defined or not
 */

static void 
check_efm_cluster_name_sudo(char *clustername, char *efm_sudo)
{
  if (clustername == NULL)
     elog(ERROR,"efm.cluster_name parameter is undefined");
  if (efm_sudo == NULL)
	elog(ERROR,"efm.edb_sudo parameter is undefined");
}

/*
 * check if efm command exists or not
 */

static void command_exists(void)
{
        int is_exists =  access(efm_path_command, F_OK);
        if ( is_exists != 0  )
                elog(ERROR,"%s %s",efm_path_command, "command not available");
}

 /* 
  * check if properties file is defined and exists
  */

static void
check_efm_properties_file(char *efm_properties)
{
   int is_exists;

   if (efm_properties == NULL)
      elog(ERROR,"efm.properties_location is undefined");

   is_exists = access(efm_properties, F_OK);
   if ( is_exists != 0  )
        elog(ERROR,"%s %s",efm_properties, "file not available");
}



/*
 * check for superuser, if its not super user then error
 */
static void
requireSuperuser(void)
{
	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 (errmsg("only superuser may access generic file functions"))));
}


/* execute a function and get output as a string */

typedef struct OutputContext
{
	FILE		*fp;
	char		*line;
	size_t 		len;
} OutputContext;

/* efm command generator */
static char * get_efm_command(char *efm_command, char *efm_argument)
{
     int   len;
     char *efm_complete_command;

     command_exists(); 
     check_efm_cluster_name_sudo(efm_cluster_name, efm_sudo);
 
     /* calculate efm comand length */
     len = strlen(efm_sudo) + 1 + strlen(efm_path_command) + 1 + strlen(efm_command) + 1 + strlen(efm_cluster_name) + 1 +strlen(efm_argument) + 1;
 
     efm_complete_command = palloc(len);
 
     snprintf(efm_complete_command, len, "%s %s %s %s %s", efm_sudo, efm_path_command, efm_command, efm_cluster_name, efm_argument);
 
     return efm_complete_command;
}

/* efm function to execute efm command for allow connection */
Datum
efm_allow_node(PG_FUNCTION_ARGS)
{
	int	result;
	char	*exec_string;

        requireSuperuser();

        exec_string = get_efm_command("allow-node", text_to_cstring(PG_GETARG_TEXT_PP(0)));
      //  elog(NOTICE,"%s",exec_string);

	result = system(exec_string);
	pfree(exec_string);
	PG_RETURN_INT32(result);
}

/* efm function to disallow node */
Datum
efm_disallow_node(PG_FUNCTION_ARGS)
{
	int	result;
	char	*exec_string;

        requireSuperuser();

        exec_string = get_efm_command("disallow-node", text_to_cstring(PG_GETARG_TEXT_PP(0)));
       // elog(NOTICE,"%s",exec_string);

	result = system(exec_string);
	pfree(exec_string);
	PG_RETURN_INT32(result);
}

/* efm function for failover */
Datum
efm_failover(PG_FUNCTION_ARGS)
{
        int     result;
        char    *exec_string;
        
        requireSuperuser();

        exec_string = get_efm_command("promote","");
      //  elog(NOTICE,"%s",exec_string);

        result = system(exec_string);
        pfree(exec_string);
        PG_RETURN_INT32(result);
}

Datum
efm_switchover(PG_FUNCTION_ARGS)
{
        int     result;
        char    *exec_string;

        requireSuperuser();

        exec_string = get_efm_command("promote","-switchover");
      //  elog(NOTICE,"%s",exec_string);

        result = system(exec_string);
        pfree(exec_string);
        PG_RETURN_INT32(result);
}

/* efm resume monitoring */
Datum
efm_resume_monitoring(PG_FUNCTION_ARGS)
{
        int     result;
        char    *exec_string;

        requireSuperuser();

        exec_string = get_efm_command("resume","");
       // elog(NOTICE,"%s",exec_string);

        result = system(exec_string);
        pfree(exec_string);
        PG_RETURN_INT32(result);
}

/* efm set priority */
Datum
efm_set_priority(PG_FUNCTION_ARGS)
{
        int     result;
        char    *exec_string;
        char    *action;
        int     len;
        char    *ipaddress = text_to_cstring(PG_GETARG_TEXT_PP(0));
        char    *priority  = text_to_cstring(PG_GETARG_TEXT_PP(1));
        len = strlen(ipaddress) + 1 + strlen(priority) + 1;
        
        requireSuperuser();
        action = palloc(len);

        snprintf(action, len, "%s %s",ipaddress, priority);

        exec_string = get_efm_command("set-priority",action);
      //  elog(NOTICE,"%s",exec_string);

        result = system(exec_string);
        pfree(exec_string);
	pfree(action);
        pfree(ipaddress);
	pfree(priority);
        PG_RETURN_INT32(result);
}


Datum
efm_cluster_status(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	OutputContext		*ocxt;
	ssize_t		read;
	text		*result;
	bool		ignore_errors = true;
        char        *output_type;

        output_type = text_to_cstring(PG_GETARG_TEXT_PP(0));

        requireSuperuser();


	if (SRF_IS_FIRSTCALL())
	{
		char		*exec_string;
		MemoryContext oldcontext;

    		if (strcmp(output_type,"text") == 0 )
				exec_string = get_efm_command("cluster-status", "" );
	        else if (strcmp(output_type,"json") == 0 )
				exec_string = get_efm_command("cluster-status-json", "" );
		else
				elog(ERROR,"unknow argument for efm_cluster_status");
		
		funcctx = SRF_FIRSTCALL_INIT();

		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
		ocxt = (OutputContext *) palloc0(sizeof(OutputContext));
		MemoryContextSwitchTo(oldcontext);
		errno = 0;
		ocxt->fp = popen(exec_string, "r");

		if 	(ocxt->fp == NULL)
		{
			if (ignore_errors)
				SRF_RETURN_DONE(funcctx);

			/*
			 * When error occurs, FMGR should free the memory allocated in the
			 * current transaction.
			 */
			elog(ERROR, "Failed to run command");
		}

		/* Make the output context available for the next calls. */
		funcctx->user_fctx = ocxt;
	}

	/*
	 * CHECK_FOR_INTERRUPTS() would make sense here, but I don't know how to
	 * ensure freeing of ocxt->line and ocxt->fp, see comments below.
	 */

	funcctx = SRF_PERCALL_SETUP();
	ocxt = funcctx->user_fctx;

	errno = 0;
	read = getline(&ocxt->line, &ocxt->len, ocxt->fp);
	/* This is serious enough to bring down the whole PG backend. */
	if (errno == EINVAL)
		elog(FATAL, "Failed to read command output.");

	if (read == -1)
	{
		/*
		 * The line buffer was allocated by getline(), so it's not under
		 * control of PG memory management. It's necessary to free it
		 * explicitly.
		 *
		 * The other chunks should be freed by PG executor.
		 */
		if (ocxt->line != NULL)
			free(ocxt->line);

		/* Another resource not controlled by PG. */
		if (pclose(ocxt->fp) != 0 && !ignore_errors)
			elog(ERROR, "Failed to run command");

		SRF_RETURN_DONE(funcctx);
	}

	if (ocxt->line[read - 1] == '\n')
		read -= 1;
	result = cstring_to_text_with_len(ocxt->line, read);

	SRF_RETURN_NEXT(funcctx, PointerGetDatum(result));
}


/*
 * function to list all the properties file content
 */
Datum
efm_list_properties(PG_FUNCTION_ARGS)
{
        FuncCallContext *funcctx;
        OutputContext           *ocxt;
        ssize_t         read;
        text            *result;
        bool            ignore_errors = false;


        requireSuperuser();


        if (SRF_IS_FIRSTCALL())
        {
                char            *exec_string;
                char            *efm_properties;
                char            *cat_properties;
                int             len;
                char            *parse_command = "| grep -v \"^#\" | sed '/^$/d'";

                MemoryContext oldcontext;
                
                len = strlen(efm_properties_file_loc) + 1 + strlen("/") + 1+ strlen(efm_cluster_name) + 1 + strlen(".properties");
                efm_properties = palloc(len);
                snprintf(efm_properties, len, "%s/%s%s",efm_properties_file_loc, efm_cluster_name, ".properties");
                check_efm_properties_file(efm_properties);

                len = strlen("cat ") + 1 + strlen(efm_properties) + 1;
                cat_properties = palloc(len);

                snprintf(cat_properties, len, "cat %s",efm_properties);
                
                len = strlen(efm_sudo) + 1 + strlen(cat_properties) + 1 + strlen(parse_command) + 1;
		exec_string = palloc(len);
                snprintf(exec_string, len, "%s %s",cat_properties,parse_command);

                funcctx = SRF_FIRSTCALL_INIT();

                oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
                ocxt = (OutputContext *) palloc0(sizeof(OutputContext));
                MemoryContextSwitchTo(oldcontext);
                errno = 0;
                ocxt->fp = popen(exec_string, "r");

                if      (ocxt->fp == NULL)
                {
                        if (ignore_errors)
                                SRF_RETURN_DONE(funcctx);

                        /*
                         * When error occurs, FMGR should free the memory allocated in the
                         * current transaction.
                         */
                        elog(ERROR, "Failed to run command");
                }

                /* Make the output context available for the next calls. */
                funcctx->user_fctx = ocxt;
        }

        /*
         * CHECK_FOR_INTERRUPTS() would make sense here, but I don't know how to
         * ensure freeing of ocxt->line and ocxt->fp, see comments below.
         */

        funcctx = SRF_PERCALL_SETUP();
        ocxt = funcctx->user_fctx;

        errno = 0;
        read = getline(&ocxt->line, &ocxt->len, ocxt->fp);
        /* This is serious enough to bring down the whole PG backend. */
        if (errno == EINVAL)
                elog(FATAL, "Failed to read command output.");

        if (read == -1)
        {
                /*
                 * The line buffer was allocated by getline(), so it's not under
                 * control of PG memory management. It's necessary to free it
                 * explicitly.
                 *
                 * The other chunks should be freed by PG executor.
                 */
                if (ocxt->line != NULL)
                        free(ocxt->line);

                /* Another resource not controlled by PG. */
                if (pclose(ocxt->fp) != 0 && !ignore_errors)
                        elog(ERROR, "Failed to run command");

                SRF_RETURN_DONE(funcctx);
        }

        if (ocxt->line[read - 1] == '\n')
                read -= 1;
        result = cstring_to_text_with_len(ocxt->line, read);

        SRF_RETURN_NEXT(funcctx, PointerGetDatum(result));
}


/* 
 * Module callback
*/

void 
_PG_init(void)
{
	DefineCustomStringVariable( "efm.cluster_name",
        	                    "Define the cluster name for efm",
                	            "It is undefined by default",
                        	    &efm_cluster_name,
                        	    NULL,
                         	    PGC_SUSET,
                         	    0, NULL, NULL, NULL);
        DefineCustomStringVariable( "efm.edb_sudo",
                                    "Define the sudo command for efm",
                                    "It is undefined by default",
                                    &efm_sudo,
                                    NULL,
                                    PGC_SUSET,
                                    0, NULL, NULL, NULL);
        DefineCustomStringVariable( "efm.command_path",
                                    "Define the command_path for efm",
                                    "It is undefined by default",
                                    &efm_path_command,
                                    NULL,
                                    PGC_SUSET,
                                    0, NULL, NULL, NULL);
        DefineCustomStringVariable( "efm.properties_location",
                                    "Define director of efm propeties file",
                                    "It is undefined by default",
                                    &efm_properties_file_loc,
                                    NULL,
                                    PGC_SUSET,
                                    0, NULL, NULL, NULL);


}
