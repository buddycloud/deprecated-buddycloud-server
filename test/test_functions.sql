-- Helper functions to add coherent data to the DB. There's dark magic in here.
CREATE FUNCTION test_set_config(node_ TEXT, key_ TEXT, value_ TEXT) RETURNS void AS $$
    DELETE FROM node_config WHERE node=node_ AND key=key_;
    INSERT INTO node_config(node, key, value, updated) VALUES(node_, key_, value_, CURRENT_TIMESTAMP);
$$ LANGUAGE SQL;

CREATE FUNCTION test_subscribe(channel TEXT, localchannel BOOLEAN, jid TEXT, localjid BOOLEAN,
                               subscription TEXT, affiliation TEXT) RETURNS void AS $$
DECLARE
    listener TEXT := NULL;
    node RECORD;
BEGIN
    IF localjid THEN
        listener := JID;
    ELSIF localchannel THEN
        listener := 'buddycloud.' || split_part(jid, '@', 2);
    END IF;

    EXECUTE 'DELETE FROM subscriptions WHERE node LIKE $1 AND "user"=$2'
        USING ('/user/' || channel || '/%'), jid;
    EXECUTE 'DELETE FROM affiliations WHERE node LIKE $1 AND "user"=$2'
        USING ('/user/' || channel || '/%'), jid;
    FOR node IN EXECUTE 'SELECT * FROM nodes WHERE node LIKE $1' USING ('/user/' || channel || '/%') LOOP
        INSERT INTO subscriptions(node, "user", listener, subscription, updated)
               VALUES (node.node, jid, listener, subscription, CURRENT_TIMESTAMP);
        INSERT INTO affiliations(node, "user", affiliation)
               VALUES (node.node, jid, affiliation);
    END LOOP;
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION test_create_channel(jid TEXT, localchan BOOLEAN DEFAULT TRUE, private BOOLEAN DEFAULT FALSE,
                                    chantype TEXT DEFAULT 'personal') RETURNS void AS $$
DECLARE
    nodes TEXT[] := ARRAY['/user/' || jid || '/posts', '/user/' || jid || '/status'];
    node TEXT;
    access_model TEXT := 'open';
BEGIN
    IF chantype = 'personal' THEN
        nodes := array_append(nodes, '/user/' || jid || '/subscriptions');
    END IF;

    IF private THEN
       access_model := 'authorize';
    END IF;

    -- "nodes" and "node_config" tables
    FOREACH node IN ARRAY nodes
    LOOP
        INSERT INTO nodes(node) VALUES(node);
        PERFORM test_set_config(node, 'creationDate',       CURRENT_TIMESTAMP::TEXT);
        PERFORM test_set_config(node, 'accessModel',        access_model);
        PERFORM test_set_config(node, 'publishModel',       'publishers');
        PERFORM test_set_config(node, 'defaultAffiliation', 'member');
        IF split_part(node, '/', 3) <> 'subscriptions' THEN
           PERFORM test_set_config(node, 'channelType',     chantype);
        END IF;
    END LOOP;

    -- rest of "node_config" table
    node := '/user/' || jid || '/posts';
    PERFORM test_set_config(node, 'title', jid);
    PERFORM test_set_config(node, 'description', 'Posts by ' || jid);

    node := '/user/' || jid || '/status';
    PERFORM test_set_config(node, 'title', jid || ' Status Updates');
    PERFORM test_set_config(node, 'description', 'M000D');

    IF chantype = 'personal' THEN
        node := '/user/' || jid || '/subscriptions';
        PERFORM test_set_config(node, 'title', jid || ' Subscriptions');
        PERFORM test_set_config(node, 'description', 'Browse my interests');
    END IF;

    -- "subscriptions" and "affiliations" tables
    PERFORM test_subscribe(jid, localchan, jid, localchan, 'subscribed', 'owner');
END;
$$ LANGUAGE plpgsql;
