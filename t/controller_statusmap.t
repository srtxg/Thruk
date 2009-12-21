use strict;
use warnings;
use Test::More tests => 6;

BEGIN { use_ok 'Catalyst::Test', 'Nagios::Web' }
BEGIN { use_ok 'Nagios::Web::Controller::statusmap' }

ok( request('/statusmap')->is_success, 'Statusmap Request should succeed' );
my $request = request('/nagios/cgi-bin/statusmap.cgi');
ok( $request->is_success, 'Statusmap Request should succeed' );
my $content = $request->content;
TODO: {
    local $TODO = "needs to be implemented";
    like($content, qr/Network Map For All Hosts/, "Content contains: Network Map For All Hosts");
};
unlike($content, qr/internal\ server\ error/mx, "Content contains error");