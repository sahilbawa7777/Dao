# The Dao System
Copyright (C) 2008-2013, Ramin Honary, all rights reserved.

THIS PROJECT IS NOT YET COMPLETE. It builds and runs, but it is still
full of bugs, and it outputs considerable debugging information.

The Dao System is a Haskell package (library), and an interactive
command line interface to this library, designed for constructing simple
artificial intelligence programs that can understand natural (human)
languages, and is licensed under the GNU Affero General Public License:
	http://www.gnu.org/licenses/agpl.html

I chose to develop the Dao language for many reasons. I could have made
use of Haskell, Python, Scheme, JavaScript, or any of the other fine
programming languages already available, but after much consideration
and experimentation, it seems that what I have in mind for Dao is rather
specific to this problem domain. My reasons for developing a new
computer language can be summarized as the following three principles
which have guided my implementation of the Dao language and interpreter:

1.	Dao is a language to build ontologies, define axioms on those
ontologies, and provides a means to map natural human language patterns
to these ontologies and the related axioms. Dao is much more concise
than XML which should make it easy to quickly write words, phrases, and
grammar as patterns, and describe the semantics of these constructs
using the Dao language. Axioms are expressed as functions (similar to
JavaScript functions) and can describe how to transform ontological data
structures to perform logic and reasoning. In a way, Dao is here to let
you write a dictionary, where the definition of words are written as a
data structures and executable script code.

2.	Dao is a scripting language extension for Haskell applications,
analogous to what Lua is for C/C++. Dao is NOT a general purpose
language. Dao is not inteded to be used for the development of APIs or
applications. You write APIs and applications in Haskell. You extend
your application with the modules in the Dao package. You extend Dao's
API with Haskell, and use Dao's foreign function interface to execute
Haskell code. Programmers can script portions of their applications in
Dao. End users can use Dao's natural language features to issue
instructions to your application, or to construct their own scripts in
an intuitive way using language that anyone understands.

3.	Dao is a laboratory containing a rich set of tools for experimenting
with artificial intelligence, with a focus on computers understanding
natural human language. The Dao system aspires to become the testing
ground for a new wave of effective, practical, natural language user
interfaces.

## How it works
The Dao scripting language is designed to be similar to JavaScript,
which is probably the most popular language in common use today (at the
time of this writing).

The Dao runtime is vaguely similar to the UNIX "AWK" language. However,
the Dao language provides a much more feature-rich set of built-in data
types and functionality as compared to AWK, notably the ability to
execute rules recursively in the same process. The Dao language makes
use of patterns called "globs" rather than POSIX regular expressions.
These glob patterns are so-called because they are inspired by UNIX
"glob" expressions, but in Dao they are more suitable for matching
against natural language input.

Patterns are optimized for faster matching of input text. Every action
associated with a matching pattern is executed in its own thread, and
concurrently with every other action. Infinite looping is prevented by
a simple heuristic: any thread executing for more than the configured
time limit is forcibly halted.

When an input string is matched against every pattern in a Dao program,
that input string is referred to as a "query." All patterns that match
the query will queue their associated subroutine which is called an
"action." Every queued "action" is executed in a separate thread. I
refer to this procedure as "executing the query against the program" or
"executing the input string."

Dao programs may import other programs as companions and execute input
queries against companion programs, as well as recursively executing
queries against itself. Imported companion programs are referred to as
"modules."

As the Dao program executes input queries, the state of the program's
working memory is changed. The working memory is similar to an
HTML/JavaScript DOM tree, but there are many more primitive types than
what JavaScript provides. This tree can be serialized and stored to the
filesystem of the host computer, and re-loaded back into memory at any
time, although Dao's own built-in binary seralization format is used
for this, not JSON. These document files are informally called "idea"
files because they allow the Dao system to store knowledge, and
transmit it to other Dao installations.

### Dao Foriegn Functions
The Dao foreign function interface provides to a Haskell programer a
method to install your own functions into a running Dao language
interpreter. Your Haskell data types can be converted to and from
intermediate tree data structures in the "Dao.Tree" module using the
'Dao.Struct.Structured' class, which requires every field of a Haskell
data type be named and updatable with a string. These strings are used
by the Dao language interpreter to update your Haskell data structures.

The Dao language intpreter borrows from the C language the concept of a
`struct`, although internally, a Dao struct is actually a tree, and the Dao
language has a similar syntax for reading or writing to fields of these
structs, which is similar to the syntax of how JavaScript modifies the
DOM tree:
```c
	person.home.email = "first.last@mail.com";
```

### Artificial Intelligence?
How this all relates to artificial intelligence is that the working
memory of a Dao program forms an ontology. Functions can be defined to
manipulate the working memory in object-oriented fashion. The patterns
that can match input queries formulate the axioms of the system. When an
input query is executed, the Dao system can use these axioms to perform
logical reasoning on the ontological objects in its working memory.

## A simple example, Dao compared to AWK

To be clear, the purpose of Dao is completely different than the purpose
of AWK. However, the Dao runtime uses a similar pattern matching and
execution algorithm to that of AWK, so comparing Dao to AWK can be
instructive.

Observe the following AWK program:
```awk
	# example.awk
	/^ *put.*in/ {
		match($0, /^put *(.*) *in *(.*) *$/, matched);
		what_to_put     = matched[1];
		print("> what to put: " what_to_put);
		where_to_put_it = matched[2];
		print("> where to put it: " where_to_put_it);
	}
	/^ *my *name *is/ {
		match($0, /^ *my *name *is *(.*) *$/, matched);
		user_name = matched[1];
		print("> Hello, " user_name "!");
	}
```

You can then interact with the AWK program like so:
```console
	% awk -f example.awk
	my name is Dave
	> Hello, Dave!
	put the data into the spreadsheet
	> what to put: the data
	> where to put it: the spreadsheet
```

AWK was not designed with natural language in mind, so it is ill-suited
to natural language systems:
* POSIX regular expressions are not designed to match
natural language input.
    1.	You need to place a Kleene-star after every space, and and
	capture "wildcards" in parentheses.
    2.	Typing mistakes, like writing "naem" instead of "name" would
	fail to behave as expected.
* It is necessary to build the "matched" array with a separate call to
the "match()" built-in function.
* Every rule is matched and executed in the order they are given in the
script. There is no concurrency.
* All variables are global.
* There is no facility to serialize the state of the program and store
it to, or reload it from, the file system.
* There is no function to force a string into the standard input, so
recursive pattern matching is not possible.

The Dao language and interpreter is designed for natural language
understanding, and addresses all of the above mentioned shortcomings.
The same program written in the Dao language would look like this:
```
	rule "put $* in $*" {
		what.to.put = $1;
		print("> what to put: " + $1);
		where.to.put = $2;
		print("> where to put it: " + $2);
	}
	rule "my name is $*" {
		user.name = $1;
		print("> Hello, " + $1);
	}
```

Dao's language is a bit more concise, both for patterns and for the
scripted actions. Dao provides ways to make pattern matching more
permissive, so that typing mistakes may also match the patterns. The
matching algorithm can be specified within the program. Future
implementations may allow for a pattern matching algorithm to take into
account contextual clues to make more accurate guesses on how to rectify
typing mistakes, and to facilitate gathering of statistical information
on input strings to better predict what an end user will type.

## History
The Dao System is the result of my masters thesis, "Natural Language
Understanding Systems using the Dao Programming Environment" published
at the Tokyo Institute of Technology in 2007. The first public release
of the Dao System was made available at <http://hackage.haskell.org> in
March of 2008, although it was mostly incomplete. The latest code is now
available at <https://github.com> . Releases will be made available at
Hackage as further progress is made.
