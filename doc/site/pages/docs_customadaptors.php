<p>DBToaster allows users to build custom adaptors for processing input streams. Such adaptors can build their own events and feed them into the query engine by calling the generated trigger functions.</p>

<p>The incremental view-maintenance (IVM) programs generated by DBToaster would be a component of your application, and in any real-world application, you will need to write your own adaptors for providing the IVM program with your data stream, as well as the operations on the data (either insert, delete, or update). Update operations in DBToaser are considered as a sequence of delete and insert operations, so it will make it even easier for you, to write your own custom data adaptors.</p>

<p>Based on the choice of your target language, either C++ or Scala, you need to write the data adaptor the same language.</p>

<?= chapter("Custom Scala Adaptors") ?>
<p>For writing your data adaptor in Scala, you should consider that the generated code for Scala consists of a class and an object with the same name. The generated object contains a default main method for quickly testing the program. Although, as you want to write your own data adaptor, you can simply ignore this generated object, and you will only need the generated class.</p>

<p>By having a look at the generated class code, you might have noticed that it is a descendant of Akka Actor class, which makes it an actor. If you are already familiar with Akka Actor, you know that each actor has a receive method that accepts a request and tries to handle that request. The generated code for each IVM program will try to handle several events in the receive method:
<ul>
	<li>StreamInit: which is an event that is meant to occur only once in the beginning of the execution.</li>
	<li>TupleEvent: that you will normally see the pattern matching for several kinds of this event. Actually, this is the main event that should occur on every database operation on the database tables.</li>
	<li>GetSnapshot: that is a request for sending back the current view result.</li>
	<li>EndOfStream: which is an event that is meant to occur only once in the end of the execution.</li>
</ul>
</p>

<p>As you might have already guessed, you only have to create these events in your custom adaptor and pass them to this generated Akka Actor to handle your request.</p>

<?= chapter("Custom C++ Adaptors") ?>

<p>Writing a custom adaptor in C++ is semantically almost the same as Scala, but implementation-wise is different. For C++, the main file for quick testing of your generated IVM programs is not generated and you can find it in the latest distribution	 tarball (under examples/code/main.cpp).</p>

<p>In this sample main.cpp file, in addition to the main function, there are two custom programs (named CustomProgram_1 and CustomProgram_2) which extend the Program class.</p>

<p>If you look into one of the generated IVM programs in C++, you will notice that a class named Program is generated. So, the two custom programs (named CustomProgram_1 and CustomProgram_2) that you have already seen in main.cpp are extending the generated Program class, and they provide a custom way of handling input to the program, and you can write your adaptor in the same way.</p>

<p>See <?= mk_link(null, "docs", "cpp"); ?> and <?= mk_link(null, "docs", "scala"); ?> for more information on some details about code generation.</p>