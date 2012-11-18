-- Let's create some data so we can do relevant unit tests.
-- "enterprise.sf" is local, "ds9.sf" and "voyager.sf" are remote.
-- Data, Odo and Neelix have private channels.
select test_create_channel('picard@enterprise.sf',  TRUE);
select test_create_channel('riker@enterprise.sf',   TRUE);
select test_create_channel('data@enterprise.sf',    TRUE, TRUE);
select test_create_channel('laforge@enterprise.sf', TRUE);

select test_create_channel('sisko@ds9.sf', FALSE);
select test_create_channel('odo@ds9.sf',   FALSE, TRUE);
select test_create_channel('dax@ds9.sf',   FALSE);

select test_create_channel('janeway@voyager.sf', FALSE);
select test_create_channel('neelix@voyager.sf',  FALSE, TRUE);
select test_create_channel('7of9@voyager.sf',    FALSE);

-- Follow matrix for the Enterprise: "X follows Y and is a ...".
--
-- | X\Y          | Picard     | Riker      | Data        | Laforge |
-- |--------------+------------+------------+-------------+---------|
-- | Picard       | owner      | moderator  |             |         |
-- | Riker        |            | owner      |             |         |
-- | Data         | member     | outcast    | owner       | member  |
-- | Laforge      | publisher  |            | member      | owner   |
-- |--------------+------------+------------+-------------+---------|
-- | publishModel | publishers | publishers | subscribers | open    |
-- | accessModel  | open       | open       | authorize   | open    |

select test_subscribe('picard@enterprise.sf',  TRUE, 'data@enterprise.sf',    TRUE, 'subscribed',   'member');
select test_subscribe('picard@enterprise.sf',  TRUE, 'laforge@enterprise.sf', TRUE, 'subscribed',   'publisher');
select test_subscribe('riker@enterprise.sf',   TRUE, 'picard@enterprise.sf',  TRUE, 'subscribed',   'moderator');
select test_subscribe('riker@enterprise.sf',   TRUE, 'data@enterprise.sf',    TRUE, 'unsubscribed', 'outcast');
select test_subscribe('data@enterprise.sf',    TRUE, 'laforge@enterprise.sf', TRUE, 'subscribed',   'member');
select test_subscribe('laforge@enterprise.sf', TRUE, 'data@enterprise.sf',    TRUE, 'subscribed',   'member');

select test_set_config('/user/data@enterprise.sf/posts',    'publishModel', 'subscribers');
select test_set_config('/user/laforge@enterprise.sf/posts', 'publishModel', 'open');

-- Picard and Sisko follow each other as publishers.
select test_subscribe('sisko@ds9.sf', FALSE, 'picard@enterprise.sf', TRUE, 'subscribed', 'publisher');
select test_subscribe('picard@enterprise.sf', TRUE, 'sisko@ds9.sf', FALSE, 'subscribed', 'publisher');

-- Now some boring channels used for testing subscriptions/affiliations without
-- changing "important" channels.
select test_create_channel('mam-user.1@enterprise.sf', TRUE);
select test_create_channel('mam-user.2@enterprise.sf', TRUE);
select test_create_channel('push.1@enterprise.sf', TRUE);
select test_create_channel('push.2@enterprise.sf', TRUE);
select test_create_channel('push.1@ds9.sf', FALSE);
select test_create_channel('push.2@ds9.sf', FALSE);

-- Local Variables:
-- sql-product: postgres
-- eval: (orgtbl-mode 1)
-- End:
