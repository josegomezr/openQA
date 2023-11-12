# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CommandServerNg::Controller::RPC;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Data::Dumper;

# <param>
#     <value><i4>41</i4></value>
# </param>
# <struct>
#     <member>
#         <name>lowerBound</name>
#         <value><i4>18</i4></value>
#     </member>
# </struct>
# <i4> or <int>	four-byte signed integer	-12
# <boolean>	0 (false) or 1 (true)	1
# <string>	string	hello world
# <double>	double-precision signed floating point number	-12.214
# <dateTime.iso8601>	date/time	19980717T14:08:55
# <base64>	base64-encoded binary	eW91IGNhbid0IHJlYWQgdGhpcyE=

sub cast_scalar_value($param) {
	# print "cast_scalar_value: ", Data::Dumper::Dumper($param && $param->text);
	return unless $param;

	if ($param->tag eq 'string'){
		return $param->text;
	}

	if ($param->tag eq 'i4' || $param->tag eq 'int' || $param->tag eq 'double'){
		return +$param->text;
	}

	if ($param->tag eq 'dateTime.iso8601'){
		# TODO: Parse iso8601
		return $param->text;
	}

	if ($param->tag eq 'boolean'){
		return !!$param->text;
	}

	# no type: string
	return $param->text;
}

sub cast_struct_value($param) {
	my $collector = {};

	$param->child_nodes('member')->map(sub($el) {
		return unless $el->tag; 

		my $key = $el->at('name')->text;
		my $value = cast_value($el->at('value *'));
		$collector->{$key} = $value;
	});

	return $collector;
}

sub cast_value($param) {
	return cast_struct_value($param) if $param && $param->tag eq 'struct';
	return cast_scalar_value($param);
}

sub cast_params($params) {
	my @collector = ();
	$params->map(sub ($element){
		push @collector, cast_value($element->at('value *'));
	});
	return @collector;
}

sub process {
	my ($self) = @_;

	# print "============\n";
	# print $self->req->body;
	# print "============\n";

	my $method_call = Mojo::DOM->new($self->req->body)->at('methodCall');

	my $fn_name = $method_call->at('methodName')->text;
	my $params = $method_call->at('params')->children;
	
	my @args = cast_params($params);

	print "Calling $fn_name with ". Mojo::JSON::encode_json(\@args) ."\n";

	sleep 3;

    $self->render(text => '<?xml version="1.0"?>
<methodResponse>
    <params>
        <param>
            <value><string>'.$fn_name.'(' .Dumper([@args]). ')</string></value>
            </param>
        </params>
    </methodResponse>', status => 200);
}

1;