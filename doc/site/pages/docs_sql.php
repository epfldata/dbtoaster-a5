<a name="create"></a>
<?= chapter("CREATE") ?>
<center>Declare a relation for use in the query.</center>
<div class="codeblock">create_statement := 
  CREATE { TABLE | STREAM } &lt;name&gt; ( &lt;schema&gt; ) 
         [&lt;source_declaration&gt;]

schema := [&lt;var_1&gt; &lt;type_1&gt; [, &lt;var_2&gt; &lt;type_2&gt; [, ...]]]

source_declaration := source_stream source_adaptor

source_stream := 
  FROM FILE '&lt;path&gt;' {
      FIXEDWIDTH &lt;bytes_per_row&gt;
    | LINE DELIMITED
    | '&lt;delim_string&gt;' DELIMITED
  } 

source_adaptor := 
  &lt;adaptor_name&gt; (
    [&lt;param_1&gt; := '&lt;value&gt;' [, &lt;param_2&gt; := '&lt;value&gt;' [, ...]]]
  )
</div>

<p>A create statement defines a relation named <tt>name</tt> with the indicated schema and declares a method for automatically populating/updating rows of that relation.</p>

<p>Each relation may be declared to be either a Stream or a Table:
<ul>
<li>Tables are static data sources.  A table is read in prior to query monitoring, and must remain constant once monitoring has started.</li>
<li>Streams are dynamic data sources.  Stream updates are read in one tuple at a time as data becomes available, and query views are updated after every update to a stream.</li>
</ul></p>

<p>The source declaration allows DBToaster (either in the interpreter, or the generated source code) to automatically update the relation.  The source declaration is optional when using DBToaster to generate source code.  User programs may manially inject updates to relations, or manually declare sources during initialization of the DBToaster-genertaed source code.
</p>

<p>A source declaration consists of stream and adaptor components.  The stream component defines where data should be read from, and how records in the data are delimited.  At present, DBToaster only supports reading tuples from files. 
</p>

<p>If the same file is referenced multiple times, the file will only be scanned once, and events will be generated in the order in which they appear in the file.
</p>

<p>The adaptor declares how to parse fields out of each record.  See below for documentation on DBToaster's standard adaptors package.
</p>

<?=section("Example")?>
<div class="codeblock">CREATE STREAM R(a int, b date)
FROM FILE 'examples/data/r.dat' LINE DELIMITED 
CSV (fields := '|')
</div>

<hr/>
<a name="select"></a>
<?=chapter("SELECT") ?>
<center>Declare a query to monitor</center>

<div class="codeblock">select_statement := 
  SELECT &lt;target_1&gt; [, &lt;target_2&gt; [, ...]] 
  FROM &lt;source_1&gt; [, &lt;source_2&gt; [, ...]]
  WHERE &lt;condition&gt;
  [GROUP BY &lt;group_vars&gt;]

target := &lt;expression&gt; [[AS] &lt;target_name&gt;] | * | *.* 
        | &lt;source_name&gt;.*

source := &lt;relation_name&gt; [[AS] &lt;source_name&gt;]
  | (&lt;select_statement&gt;) [AS] &lt;source_name&gt;
  | &lt;source&gt; [NATURAL] JOIN &lt;source&gt; [ON &lt;condition&gt;]

expression :=  (&lt;expression&gt;) | &lt;int&gt; | &lt;float&gt; | '&lt;string&gt;' 
  | &lt;var&gt; | &lt;source&gt;.&lt;var&gt;
  | &lt;expression&gt; { + | - | * | / } &lt;expression&gt;
  | -&lt;expression&gt;
  | (SELECT &lt;expression&gt; FROM ...)
  | SUM(&lt;expression&gt;) | COUNT(* | &lt;expression&gt;) 
  | AVG(&lt;expression&gt;) | COUNT(DISTINCT [var1, [var2, [...]]])
  | &lt;inline_function&gt;([&lt;expr_1&gt; [, &lt;expr_2&gt; [, ...]]])
  | DATE('yyyy-mm-dd')
  | EXTRACT({year|month|day} FROM &lt;date&gt;)
  | CASE &lt;expression&gt; WHEN &lt;expression&gt; THEN &lt;expression&gt; [, ...] 
                      [ELSE &lt;expression&gt;] END
  | CASE WHEN &lt;condition&gt; THEN &lt;expression&gt; [, ...] 
         [ELSE &lt;expression&gt;] END

condition := (&lt;condition&gt;) | true | false | not (&lt;condition&gt;)
  | &lt;expression&gt; { < | <= | > | >= | = | <> } &lt;expression&gt;
  | &lt;expression&gt; { < | <= | > | >= | = | <> } { SOME | ALL } 
                   &lt;select_statement&gt;
  | &lt;condition&gt; AND &lt;condition&gt; | &lt;condition&gt; OR &lt;condition&gt;
  | EXISTS &lt;select_statement&gt;
  | &lt;expression&gt; BETWEEN &lt;expression&gt; AND &lt;expression&gt;
  | &lt;expression&gt; IN &lt;select_statement&gt;
  | &lt;expression&gt; LIKE &lt;matchstring&gt;
  

</div>

<p>DBToaster SQL's SELECT operation differs from the SQL-92 standard.  Full support for the SQL-standard SELECT is planned, and will be part of a future release.</p>

<dl>
<dt><b>Aggregates</b></dt>
<dd>DBToaster currently has support for the SUM, COUNT, COUNT DISTINCT, and AVG aggregates.  MIN and MAX are not presently supported.  Also, see the note on NULL values below.

<dt><b>Types</b></dt>
<dd>DBToaster presently supports integer, floating point, string, and date types.  char and varchar types are treated as strings of unbounded length.</dd>

<dt><b>Conditional Predicates</b></dt>
<dd>DBToaster presently supports boolean expressions over arithmetic comparisons (=, <>, <, <=, >, >=), existential/universal quantification (SOME/ALL/EXISTS), BETWEEN, IN, and LIKE.</dd>

<dt><b>SELECT syntax</b></dt>
<dd>SELECT [FROM] [WHERE] [GROUP BY] queries are supported.  The DISTINCT, UNION, LIMIT, ORDER BY, and HAVING clauses are not presently supported.  The HAVING operator may be simulated by use of nested queries:
<div class="codeblock">SELECT A, SUM(B) AS sumb FROM R HAVING SUM(C) > 2</div>
is equivalent to
<div class="codeblock">SELECT A, sumb FROM (
  SELECT A, SUM(B) AS sumb, SUM(C) as sumc FROM R
)
WHERE sumc > 2</div>

</dd>

<dt><b>NULL values</b></dt>
<dd>DBToaster does not presently support NULL values.  The SUM or AVERAGE of an empty table is 0, and not NULL.  OUTER JOINS are not supported.</dd>

<dt><b>Other Notes</b></dt>
<dd>
<ul>
<li>Support for division is limited.  DBToaster does not currently check for, or react to divide by zero errors.  If a result value ever becomes NAN or INFTY, it will no longer be possible to incrementally maintain it.</li>
<li>DBToaster does not allow non-aggregate queries to evaluate to singleton values.  That is, the query
<div class="codeblock">SELECT 1 FROM R WHERE R.A = (SELECT A FROM S)</div>
is a compile-time error in DBToaster (while such a query would instead produce a run time error if it returned more than one tuple in SQL-92).  An equivalent, valid query would be:<br/>
<div class="codeblock">SELECT 1 FROM R WHERE R.A IN (SELECT A FROM S)</div></li>
<li>Variable scoping rules are slightly stricter than the SQL standard (you may need to use fully qualified names in some additional cases).</li>
</ul>
</dd>
</dl>
</p>

<p>See the <a href="index.php?page=docs&subpage=stdlib">Standard Functions Documentation</a> for documentation on DBToaster's standard function library.</p>

<p>DBToaster maintains query results in the form of either multi-key dictionaries (a.k.a., maps, hashmaps, etc...), or singleton primitive-typed values.  Each query result is assigned a name based on the query (see documentation for your target language's code generator for details on how to access the results).<p>
<ul>
<li>Non-aggregate queries produce a dictionary named "COUNT".  Each entry in the dictionary has a key formed from the target fields of the SELECT.  Values are the number of times the tuple occurs in the output (i.e., the query includes an implicit group-by COUNT(*) aggregate).</li>
<li>Singleton (non-grouping) aggregate queries produce a primitive-typed result for each aggregate target in the SELECT.  The result names are assigned based on the name of each target (i.e., using the name following the optional <tt>AS</tt> clause, or a procedurally generated name otherwise).</li>
<li>Group-by aggregate queries produce a dictionary for each aggregate target.  The non-aggregate (group-by) targets are used as keys for each entry (as for non-aggregate queries), and the value is the aggregate value for each group.  The dictionaries are named based on the name of each aggregate target (as for singleton aggregate queries)</li>
</ul></p>

<p>If multiple SELECT statements occur in the same file, the result names of each query will be prefixed with "QUERY#_", where # is an integer.</p>

<?=section("Examples")?>

<div class="codeblock">CREATE STREAM R(A int, B int);
CREATE STREAM S(B int, C int);</div>

<?=subsection("Non-aggregate query")?>
<div class="codeblock">SELECT * FROM R;</div>
Generates a single dictionary named COUNT, mapping from the tuple "&lt;R.A, R.B&gt;" to the number of time each tuple occurs in R.

<?=subsection("Aggregate query")?>
<div class="codeblock">SELECT SUM(R.A * S.C) AS sum_ac FROM R NATURAL JOIN S;</div>
Generates a single constant integer named SUM_AC containing the query result.

<?=subsection("Aggregate group-by query (one group-by var)")?>
<div class="codeblock">SELECT S.C, SUM(R.A) AS sum_a 
FROM R NATURAL JOIN S 
GROUP BY S.C;</div>
Generates a dictionary named SUM_A mapping from values of S.C to the sums of R.A.

<?=subsection("Aggregate group-by query (multiple group-by vars)")?>
<div class="codeblock">SELECT R.A, R.B, COUNT(*) AS foo FROM R GROUP BY R.A, R.B;</div>
Generates a single dictionary named FOO, mapping from the tuple "&lt;R.A, R.B&gt;" to the number of time each tuple occurs in R.

<?=subsection("Query with multiple aggregates")?>
<div class="codeblock">SELECT SUM(R.A) AS sum_a, SUM(S.C) AS sum_c 
FROM R NATURAL JOIN S 
GROUP BY S.C;</div>
Generates two dictionaries named SUM_A and SUM_C, respectively containing the sums of R.A and S.C.

<hr/>

<a name="include"></a>
<?=chapter("INCLUDE") ?>
<div class="codeblock">include_statement := INCLUDE 'file'
</div>

Import the contents of the selected file into DBToaster.  The file path is interpreted relative to the current working directory.
