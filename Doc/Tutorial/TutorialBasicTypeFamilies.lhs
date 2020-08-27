> {-# LANGUAGE FlexibleContexts #-}
> {-# LANGUAGE FlexibleInstances #-}
> {-# LANGUAGE MultiParamTypeClasses #-}
> {-# LANGUAGE UndecidableInstances #-}
>
> {-# LANGUAGE TypeFamilies #-}
> {-# LANGUAGE EmptyDataDecls #-}
> {-# LANGUAGE FunctionalDependencies #-}
> {-# LANGUAGE NoMonomorphismRestriction #-}
> {-# LANGUAGE DataKinds #-}
> {-# LANGUAGE TypeOperators #-}
>
> module TutorialBasicTypeFamilies where
>
> import           Prelude hiding (sum)
>
> import           Opaleye (Field,
>                          Table, table, tableField, selectTable,
>                          Select, (.==), aggregate, groupBy,
>                          count, avg, sum, leftJoin, runSelect, runSelectTF,
>                          showSql, Unpackspec,
>                          SqlInt4, SqlInt8, SqlText, SqlDate, SqlFloat8)
>
> import qualified Opaleye.Join         as OJ
> import           Opaleye.TypeFamilies (O, H, NN, Req, Nulls, W,
>                                        TableRecordField,
>                                        (:<$>), (:<*>))
>
> import qualified Data.Profunctor         as P
> import qualified Data.Profunctor.Product as PP
> import           Data.Profunctor.Product (p3)
> import           Data.Profunctor.Product.Default (Default)
> import qualified Data.Profunctor.Product.Default as D
>
> import           Data.Time.Calendar (Day)
>
> import qualified Database.PostgreSQL.Simple as PGS

Introduction
============

In this example file I'll give you a brief introduction to the Opaleye
relational query EDSL.  I'll show you how to define tables in Opaleye;
use them to generate selects, joins and filters; use the API of
Opaleye to make your queries more composable; and finally run the
queries on Postgres.

Schema
======

Opaleye assumes that a Postgres database already exists.  Currently
there is no support for creating databases or tables, though these
features may be added later according to demand.

A table is defined with the `table` function.  The syntax is
simple.  You specify the types of the fields, the name of the table
and the names of the fields in the underlying database.

(Note: This simple syntax is supported by an extra combinator that
describes the shape of the container that you are storing the fields
in.  In the first example we are using a tuple of size 3 and the
combinator is called `p3`.  We'll see examples of others later.)

The `Table` type constructor has two arguments.  The first one tells
us what fields we can write to the table and the second what fields
we can read from the table.  In this case all fields are required, so
the write and read types will be the same.

> personTable :: Table (Field SqlText, Field SqlInt4, Field SqlText)
>                      (Field SqlText, Field SqlInt4, Field SqlText)
> personTable = table "personTable" (p3 ( tableField "name"
>                                       , tableField "age"
>                                       , tableField "address" ))

By default, the table `"personTable"` is looked up in PostgreSQL's
default `"public"` schema. If we wanted to specify a different schema we
could have used the `tableWithSchema` function instead of `table`.

To select from a table we use `selectTable`.

(Here and in a few other places in Opaleye there is some typeclass
magic going on behind the scenes to reduce boilerplate.  However, you
never *have* to use typeclasses.  All the magic that typeclasses do is
also available by explicitly passing in the "typeclass dictionary".
For this example file we will always use the typeclass versions
because they are simpler to read and the typeclass magic is
essentially invisible.)

> personSelect :: Select (Field SqlText, Field SqlInt4, Field SqlText)
> personSelect = selectTable personTable

A `Select` corresponds to an SQL SELECT that we can run.  Here is the
SQL generated for `personSelect`.  (`printSQL` is just a convenient
utility function for the purposes of this example file.  See below for
its definition.)

    ghci> printSql personSelect
    SELECT name0_1 as result1,
           age1_1 as result2,
           address2_1 as result3
    FROM (SELECT *
          FROM (SELECT name as name0_1,
                       age as age1_1,
                       address as address2_1
                FROM personTable as T1) as T1) as T1

This SQL is functionally equivalent to the following "idealized" SQL.
In this document every example of SQL generated by Opaleye will be
followed by an "idealized" equivalent version.  This will give you
some idea of how readable the SQL generated by Opaleye is.  Eventually
Opaleye should generate SQL closer to the "idealized" version, but
that is an ongoing project.  Since Postgres has a sensible query
optimization engine there should be little difference in performance
between Opaleye's version and the ideal.  Please submit any
differences encountered in practice as an Opaleye bug.

    SELECT name,
           age
           address
    FROM personTable


Record types
------------

Opaleye can use user defined types such as record types in queries.

Contrary to popular belief, you don't have to define your data types
to be polymorphic in all their fields.  In fact there's a nice scheme
using type families that reduces boiler plate and has always been
compatible with Opaleye!

> data Birthday f = Birthday { bdName :: TableRecordField f String SqlText NN Req
>                            , bdDay  :: TableRecordField f Day    SqlDate NN Req
>                            }

This instance, adaptor and type family are fully derivable by Template
Haskell or generics but I haven't got round to writing that yet.
Please volunteer to do that if you can.

> instance ( PP.ProductProfunctor p
>          , Default p (TableRecordField a String SqlText NN Req)
>                      (TableRecordField b String SqlText NN Req)
>          , Default p (TableRecordField a Day    SqlDate NN Req)
>                      (TableRecordField b Day    SqlDate NN Req)) =>
>   Default p (Birthday a) (Birthday b) where
>   def = pBirthday (Birthday D.def D.def)
>
> pBirthday :: PP.ProductProfunctor p
>           => Birthday (p :<$> a :<*> b)
>           -> p (Birthday a) (Birthday b)
> pBirthday b = Birthday PP.***$ P.lmap bdName (bdName b)
>                        PP.**** P.lmap bdDay  (bdDay b)

Then we can use 'table' to make a table on our record type in exactly
the same way as before.

> birthdayTable :: Table (Birthday W) (Birthday O)
> birthdayTable = table "birthdayTable" $ pBirthday $ Birthday {
>     bdName = tableField "name"
>   , bdDay  = tableField "birthday"
> }
>
> birthdaySelect :: Select (Birthday O)
> birthdaySelect = selectTable birthdayTable

    ghci> printSql birthdaySelect
    SELECT name0_1 as result1,
           birthday1_1 as result2
    FROM (SELECT *
          FROM (SELECT name as name0_1,
                       birthday as birthday1_1
                FROM birthdayTable as T1) as T1) as T1

Idealized SQL:

    SELECT name,
           birthday
    FROM birthdayTable


Aggregation
===========

Type safe aggregation is the jewel in the crown of Opaleye.  Even SQL
generating APIs which are otherwise type safe often fall down when it
comes to aggregation.  If you want to find holes in the type system of
an SQL generating language, aggregation is the best place to look!  By
contrast, Opaleye aggregations always generate meaningful SQL.

By way of example, suppose we have a widget table which contains the
style, color, location, quantity and radius of widgets.  We can model
this information with the following datatype.

> data Widget f = Widget { style    :: TableRecordField f String SqlText   NN Req
>                        , color    :: TableRecordField f String SqlText   NN Req
>                        , location :: TableRecordField f String SqlText   NN Req
>                        , quantity :: TableRecordField f Int    SqlInt4   NN Req
>                        , radius   :: TableRecordField f Double SqlFloat8 NN Req
>                        }

This instance, adaptor and type family are fully derivable but no
one's implemented the Template Haskell or generics to do that yet.

> instance ( PP.ProductProfunctor p
>          , Default p (TableRecordField a String SqlText NN Req)
>                      (TableRecordField b String SqlText NN Req)
>          , Default p (TableRecordField a Int    SqlInt4 NN Req)
>                      (TableRecordField b Int    SqlInt4 NN Req)
>          , Default p (TableRecordField a Double SqlFloat8 NN Req)
>                      (TableRecordField b Double SqlFloat8 NN Req)) =>
>   Default p (Widget a) (Widget b) where
>   def = pWidget (Widget D.def D.def D.def D.def D.def)
>
> pWidget :: PP.ProductProfunctor p
>         => Widget (p :<$> a :<*> b)
>         -> p (Widget a) (Widget b)
> pWidget w = Widget PP.***$ P.lmap style    (style w)
>                    PP.**** P.lmap color    (color w)
>                    PP.**** P.lmap location (location w)
>                    PP.**** P.lmap quantity (quantity w)
>                    PP.**** P.lmap radius   (radius w)

For the purposes of this example the style, color and location will be
strings, but in practice they might have been a different data type.

> widgetTable :: Table (Widget W) (Widget O)
> widgetTable = table "widgetTable" $ pWidget $ Widget {
>     style    = tableField "style"
>   , color    = tableField "color"
>   , location = tableField "location"
>   , quantity = tableField "quantity"
>   , radius   = tableField "radius"
> }

Say we want to group by the style and color of widgets, calculating
how many (possibly duplicated) locations there are, the total number
of such widgets and their average radius.  `aggregateWidgets` shows us
how to do this.

> aggregateWidgets :: Select (Field SqlText, Field SqlText, Field SqlInt8,
>                            Field SqlInt4, Field SqlFloat8)
> aggregateWidgets = aggregate ((,,,,) <$> P.lmap style    groupBy
>                                      <*> P.lmap color    groupBy
>                                      <*> P.lmap location count
>                                      <*> P.lmap quantity sum
>                                      <*> P.lmap radius   avg)
>                              (selectTable widgetTable)

The generated SQL is

    ghci> printSql aggregateWidgets
    SELECT result0_2 as result1,
           result1_2 as result2,
           result2_2 as result3,
           result3_2 as result4,
           result4_2 as result5
    FROM (SELECT *
          FROM (SELECT style0_1 as result0_2,
                       color1_1 as result1_2,
                       COUNT(location2_1) as result2_2,
                       SUM(quantity3_1) as result3_2,
                       AVG(radius4_1) as result4_2
                FROM (SELECT *
                      FROM (SELECT style as style0_1,
                                   color as color1_1,
                                   location as location2_1,
                                   quantity as quantity3_1,
                                   radius as radius4_1
                            FROM widgetTable as T1) as T1) as T1
                GROUP BY style0_1,
                         color1_1) as T1) as T1

Idealized SQL:

    SELECT style,
           color,
           COUNT(location),
           SUM(quantity),
           AVG(radius)
    FROM widgetTable
    GROUP BY style, color

Note: In `widgetTable` and `aggregateWidgets` we see more explicit
uses of our Template Haskell derived code.  We use the 'pWidget'
"adaptor" to specify how fields are aggregated.

Outer join
==========

Opaleye supports outer joins (i.e. left joins, right joins and full
outer joins).  An outer join is expressed by specifying the two tables
to join and the join condition.

> personBirthdayLeftJoin :: Select ((Field SqlText, Field SqlInt4, Field SqlText),
>                                  Birthday Nulls)
> personBirthdayLeftJoin = leftJoin personSelect birthdaySelect eqName
>     where eqName ((name, _, _), birthdayRow) = name .== bdName birthdayRow

The generated SQL is

    ghci> printSql personBirthdayLeftJoin
    SELECT result1_0_3 as result1,
           result1_1_3 as result2,
           result1_2_3 as result3,
           result2_0_3 as result4,
           result2_1_3 as result5
    FROM (SELECT *
          FROM (SELECT name0_1 as result1_0_3,
                       age1_1 as result1_1_3,
                       address2_1 as result1_2_3,
                       name0_2 as result2_0_3,
                       birthday1_2 as result2_1_3
                FROM
                (SELECT *
                 FROM (SELECT name as name0_1,
                              age as age1_1,
                              address as address2_1
                       FROM personTable as T1) as T1) as T1
                LEFT OUTER JOIN
                (SELECT *
                 FROM (SELECT name as name0_2,
                              birthday as birthday1_2
                       FROM birthdayTable as T1) as T1) as T2
                ON
                (name0_1) = (name0_2)) as T1) as T1

Idealized SQL:

    SELECT name0,
           age0,
           address0,
           name1,
           birthday1
    FROM (SELECT name as name0,
                 age as age0,
                 address as address0
          FROM personTable) as T1
         LEFT OUTER JOIN
         (SELECT name as name1,
                 birthday as birthday1
          FROM birthdayTable) as T1
    ON name0 = name1

Types of joins are inferrable in new versions of Opaleye.  Here is a
(rather silly) example.

> typeInferred = do
>     bd  <- birthdaySelect
>     w   <- OJ.optional (selectTable widgetTable)
>     bd' <- OJ.optional birthdaySelect
>     pure (bd, w, bd')

Running queries on Postgres
===========================


Opaleye provides simple facilities for running queries on Postgres.
`runSelect` is a typeclass polymorphic function that effectively has
the following type

> -- runSelect :: Database.PostgreSQL.Simple.Connection
> --          -> Select fields -> IO [haskells]

It converts a "record" of Opaleye fields to a list of "records" of
Haskell values.  Like `leftJoin` this particular formulation uses
typeclasses so please put type signatures on everything in sight to
minimize the number of confusing error messages!

> runBirthdaySelect :: PGS.Connection
>                  -> Select (Birthday O)
>                  -> IO [Birthday H]
> runBirthdaySelect = runSelect

The type of selects can be inferred if you use the `runSelectTF`
function.

> -- printNames :: PGS.Connection -> Select (Birthday O) -> IO ()
> printNames conn select = mapM_ (print . bdName) =<< runSelectTF conn select

Conclusion
==========

There ends the Opaleye introductions module.  Please send me your questions!

Utilities
=========

This is a little utility function to help with printing generated SQL.

> printSql :: Default Unpackspec a a => Select a -> IO ()
> printSql = putStrLn . maybe "Empty select" id . showSql
