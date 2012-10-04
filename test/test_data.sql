-- Let's create some data so we can do relevant unit tests.
-- "enterprise.sf" is local, "ds9.sf" and "voyager.sf" are remote.
-- Data, Odo and Neelix have private channels.
select test_create_channel('picard@enterprise.sf',  TRUE);
select test_create_channel('data@enterprise.sf',    TRUE, TRUE);
select test_create_channel('laforge@enterprise.sf', TRUE);

select test_create_channel('sisko@ds9.sf', FALSE);
select test_create_channel('odo@ds9.sf',   FALSE, TRUE);
select test_create_channel('dax@ds9.sf',   FALSE);

select test_create_channel('janeway@voyager.sf', FALSE);
select test_create_channel('neelix@voyager.sf',  FALSE, TRUE);
select test_create_channel('7of9@voyager.sf',    FALSE);

-- Data and Laforge follow Picard. Data is a member, Laforge a publisher.
select test_subscribe('picard@enterprise.sf', TRUE, 'data@enterprise.sf',    TRUE, 'subscribed', 'member');
select test_subscribe('picard@enterprise.sf', TRUE, 'laforge@enterprise.sf', TRUE, 'subscribed', 'publisher');

-- Picard and Sisko follow each other as publishers
select test_subscribe('sisko@ds9.sf', FALSE, 'picard@enterprise.sf', TRUE, 'subscribed', 'publisher');
select test_subscribe('picard@enterprise.sf', TRUE, 'sisko@ds9.sf', FALSE, 'subscribed', 'publisher');
