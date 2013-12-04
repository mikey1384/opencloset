#!/usr/bin/env perl

use v5.18;
use Mojolicious::Lite;

use Data::Pageset;
use DateTime;
use List::MoreUtils qw( zip );
use SMS::Send::KR::CoolSMS;
use SMS::Send;
use Try::Tiny;

use Opencloset::Constant;
use Opencloset::Schema;

plugin 'validator';
plugin 'haml_renderer';
plugin 'FillInFormLite';

my @CATEGORIES = qw( jacket pants shirt shoes hat tie waistcoat coat onepiece skirt blouse belt );

app->defaults( %{ plugin 'Config' => { default => {
    jses        => [],
    csses       => [],
    breadcrumbs => [],
    active_id   => q{},
}}});

my $DB = Opencloset::Schema->connect({
    dsn      => app->config->{database}{dsn},
    user     => app->config->{database}{user},
    password => app->config->{database}{pass},
    %{ app->config->{database}{opts} },
});

helper error => sub {
    my ($self, $status, $error) = @_;

    ## TODO: `ok.haml.html`, `bad_request.haml.html`, `internal_error.haml.html`
    my %error_map = (
        200 => 'ok',
        400 => 'bad_request',
        404 => 'not_found',
        500 => 'internal_error',
    );

    $self->respond_to(
        json => { json => { error => $error || '' }, status => $status },
        html => {
            template => $error_map{$status},
            error    => $error || '',
            status   => $status
        }
    );
};

helper cloth_validator => sub {
    my $self = shift;

    my $validator = $self->create_validator;
    $validator->field('category')->required(1);
    $validator->field('gender')->required(1)->regexp(qr/^[123]$/);

    # jacket
    $validator->when('category')->regexp(qr/jacket/)
        ->then(sub { shift->field(qw/ bust arm /)->required(1) });

    # pants, skirts
    $validator->when('category')->regexp(qr/(pants|skirt)/)
        ->then(sub { shift->field(qw/ waist length /)->required(1) });

    # shoes
    $validator->when('category')->regexp(qr/^shoes$/)
        ->then(sub { shift->field('length')->required(1) });

    $validator->field(qw/ bust waist hip arm length /)
        ->each(sub { shift->regexp(qr/^\d+$/) });

    return $validator;
};

helper cloth2hr => sub {
    my ($self, $clothes) = @_;

    return {
        $clothes->get_columns,
        donor    => $clothes->donor ? $clothes->user->name : '',
        category => $clothes->category,
        price    => $self->commify($clothes->price),
        status   => $clothes->status->name,
    };
};

helper order2hr => sub {
    my ($self, $order) = @_;

    my @clothes_list;
    for my $clothes ($order->cloths) {
        push @clothes_list, $self->cloth2hr($clothes);
    }

    return {
        $order->get_columns,
        clothes_list => \@clothes_list
    };
};

helper sms2hr => sub {
    my ($self, $sms) = @_;

    return { $sms->get_columns };
};

helper calc_overdue => sub {
    my ( $self, $target_dt, $return_dt ) = @_;

    return unless $target_dt;

    $return_dt ||= DateTime->now;

    my $DAY_AS_SECONDS = 60 * 60 * 24;

    my $epoch1 = $target_dt->epoch;
    my $epoch2 = $return_dt->epoch;

    my $dur = $epoch2 - $epoch1;
    return 0 if $dur < 0;
    return int($dur / $DAY_AS_SECONDS);
};

helper commify => sub {
    my $self = shift;
    local $_ = shift;
    1 while s/((?:\A|[^.0-9])[-+]?\d+)(\d{3})/$1,$2/s;
    return $_;
};

helper calc_late_fee => sub {
    my ( $self, $order, $commify ) = @_;

    my $overdue  = $self->calc_overdue( $order->target_date );
    my $late_fee = $order->price * 0.2 * $overdue;

    return $commify ? $self->commify($late_fee) : $late_fee;
};


helper user_validator => sub {
    my $self = shift;

    my $validator = $self->create_validator;
    $validator->field('name')->required(1);
    $validator->field('phone')->regexp(qr/^01\d{8,9}$/);
    $validator->field('email')->email;
    $validator->field('gender')->regexp(qr/^[12]$/);
    $validator->field('age')->regexp(qr/^\d+$/);

    ## TODO: check exist email and set to error
    return $validator;
};

helper create_user => sub {
    my $self = shift;

    my %params;
    map {
        $params{$_} = $self->param($_) if defined $self->param($_)
    } qw/name email password phone gender age address/;

    return $DB->resultset('User')->find_or_create(\%params);
};

helper guest_validator => sub {
    my $self = shift;

    my $validator = $self->create_validator;
    $validator->field([qw/bust waist arm length height weight/])
        ->each(sub { shift->required(1)->regexp(qr/^\d+$/) });

    ## TODO: validate `target_date`
    return $validator;
};

helper create_cloth => sub {
    my ($self, %info) = @_;

    #
    # FIXME generate code
    #
    my $code;
    {
        my $clothes = $DB->resultset('Clothes')->search(
            { category => $info{category} },
            { order_by => { -desc => 'code' } },
        )->next;

        my $index = 1;
        if ($clothes) {
            $index = substr $clothes->code, -5, 5;
            $index =~ s/^0+//;
            $index++;
        }

        $code = sprintf '%05d', $index;
    }

    #
    # tune params to create clothes
    #
    my %params = (
        code            => $code,
        donor_id        => $self->param('donor_id') || undef,
        category        => $info{category},
        status_id       => $Opencloset::Constant::STATUS_AVAILABLE,
        gender          => $info{gender},
        color           => $info{color},
        compatible_code => $info{compatible_code},
    );
    {
        no warnings 'experimental';

        my @keys;
        given ( $info{category} ) {
            @keys = qw( bust arm )          when /^(jacket|shirt|waistcoat|coat|blouse)$/i;
            @keys = qw( waist length )      when /^(pants|skirt)$/i;
            @keys = qw( bust waist length ) when /^(onepiece)$/i;
            @keys = qw( length )            when /^(shoes)$/i;
        }
        map { $params{$_} = $info{$_} } @keys;
    }

    my $new_cloth = $DB->resultset('Clothes')->find_or_create(\%params);
    return unless $new_cloth;
    return $new_cloth unless $new_cloth->compatible_code;

    my $compatible_code = $new_cloth->compatible_code;
    $compatible_code =~ s/[A-Z]/_/g;
    my $top_or_bottom = $DB->resultset('Clothes')->search({
        category        => { '!=' => $new_cloth->category },
        compatible_code => { like => $compatible_code },
    })->next;

    if ($top_or_bottom) {
        no warnings 'experimental';
        given ( $top_or_bottom->category ) {
            when ( /^(jacket|shirt|waistcoat|coat|blouse)$/i ) {
                $new_cloth->top_id($top_or_bottom->id);
                $top_or_bottom->bottom_id($new_cloth->id);
                $new_cloth->update;
                $top_or_bottom->update;
            }
            when ( /^(pants|skirt)$/i ) {
                $new_cloth->bottom_id($top_or_bottom->id);
                $top_or_bottom->top_id($new_cloth->id);
                $new_cloth->update;
                $top_or_bottom->update;
            }
        }
    }

    return $new_cloth;
};

helper _q => sub {
    my ($self, %params) = @_;

    my $q = $self->param('q') || q{};
    my ( $bust, $waist, $arm, $status_id, $category ) = split /\//, $q;
    my %q = (
        bust     => $bust      || '',
        waist    => $waist     || '',
        arm      => $arm       || '',
        status   => $status_id || '',
        category => $category  || '',
        %params,
    );

    return join '/', ( $q{bust}, $q{waist}, $q{arm}, $q{status}, $q{category} );
};

helper get_params => sub {
    my ( $self, @keys ) = @_;

    #
    # parameter can have multiple values
    #
    my @values;
    for my $k (@keys) {
        my @v = $self->param($k);
        if ( @v > 1 ) {
            push @values, \@v;
        }
        else {
            push @values, $v[0];
        }
    }

    #
    # make parameter hash using explicit keys
    #
    my %params = zip @keys, @values;

    #
    # remove not defined parameter key and values
    #
    defined $params{$_} ? 1 : delete $params{$_} for keys %params;

    return %params;
};

#
# API section
#
group {
    under '/api' => sub {
        my $self = shift;

        #
        # FIXME - need authorization
        #
        if (1) {
            return 1;
        }

        $self->render( json => { error => 'invalid_access' }, status => 400 );
        return;
    };

    post '/user'          => \&api_create_user;
    get  '/user/:id'      => \&api_get_user;
    put  '/user/:id'      => \&api_update_user;
    del  '/user/:id'      => \&api_delete_user;

    get  '/user-list'     => \&api_get_user_list;

    post '/order'         => \&api_create_order;
    get  '/order/:id'     => \&api_get_order;
    put  '/order/:id'     => \&api_update_order;
    del  '/order/:id'     => \&api_delete_order;

    get  '/order-list'    => \&api_get_order_list;

    post '/clothes'       => \&api_create_clothes;
    get  '/clothes/:code' => \&api_get_clothes;
    put  '/clothes/:code' => \&api_update_clothes;
    del  '/clothes/:code' => \&api_delete_clothes;

    get  '/clothes-list'  => \&api_get_clothes_list;
    put  '/clothes-list'  => \&api_update_clothes_list;

    sub api_create_user {
        my $self = shift;

        #
        # fetch params
        #
        my %user_params      = $self->get_params(qw/ name email password /);
        my %user_info_params = $self->get_params(qw/
            phone  address gender birth comment
            height weight  bust   waist hip
            thigh  arm     leg    knee  foot
        /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('name')->required(1);
        $v->field('email')->email;
        $v->field('phone')->regexp(qr/^\d+$/);
        $v->field('gender')->in(qw/ male female /);
        $v->field('birth')->regexp(qr/^(19|20)\d{2}$/);
        $v->field(qw/ height weight bust waist hip thigh arm leg knee foot /)->each(sub {
            shift->regexp(qr/^\d{1,3}$/);
        });
        unless ( $self->validate( $v, { %user_params, %user_info_params } ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # create user
        #
        my $user = do {
            my $guard = $DB->txn_scope_guard;

            my $user = $DB->resultset('User')->create(\%user_params);
            return $self->error( 500, {
                str  => 'failed to create a new user',
                data => {},
            }) unless $user;

            my $user_info = $DB->resultset('UserInfo')->create({
                %user_info_params,
                user_id => $user->id,
            });
            return $self->error( 500, {
                str  => 'failed to create a new user info',
                data => {},
            }) unless $user_info;

            $guard->commit;

            $user;
        };

        #
        # response
        #
        my %data = ( $user->user_info->get_columns, $user->get_columns );
        delete @data{qw/ user_id password /};

        $self->res->headers->header(
            'Location' => $self->url_for( '/api/user/' . $user->id ),
        );
        $self->respond_to( json => { status => 201, json => \%data } );
    }

    sub api_get_user {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/ id /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('id')->required(1)->regexp(qr/^\d+$/);
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # find user
        #
        my $user = $DB->resultset('User')->find( \%params );
        return $self->error( 404, {
            str  => 'user not found',
            data => {},
        }) unless $user;
        return $self->error( 404, {
            str  => 'user info not found',
            data => {},
        }) unless $user->user_info;

        #
        # response
        #
        my %data = ( $user->user_info->get_columns, $user->get_columns );
        delete @data{qw/ user_id password /};

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_update_user {
        my $self = shift;

        #
        # fetch params
        #
        my %user_params      = $self->get_params(qw/ id name email password /);
        my %user_info_params = $self->get_params(qw/
            phone  address gender birth comment
            height weight  bust   waist hip
            thigh  arm     leg    knee  foot
        /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('id')->required(1)->regexp(qr/^\d+$/);
        $v->field('email')->email;
        $v->field('phone')->regexp(qr/^\d+$/);
        $v->field('gender')->in(qw/ male female /);
        $v->field('birth')->regexp(qr/^(19|20)\d{2}$/);
        $v->field(qw/ height weight bust waist hip thigh arm leg knee foot /)->each(sub {
            shift->regexp(qr/^\d{1,3}$/);
        });
        unless ( $self->validate( $v, { %user_params, %user_info_params } ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # find user
        #
        my $user = $DB->resultset('User')->find({ id => $user_params{id} });
        return $self->error( 404, {
            str  => 'user not found',
            data => {},
        }) unless $user;
        return $self->error( 404, {
            str  => 'user info not found',
            data => {},
        }) unless $user->user_info;

        #
        # update user
        #
        {
            my $guard = $DB->txn_scope_guard;

            my %_user_params = %user_params;
            delete $_user_params{id};
            $user->update( \%_user_params )
                or return $self->error( 500, {
                    str  => 'failed to update a user',
                    data => {},
                });

            $user->user_info->update({
                %user_info_params,
                user_id => $user->id,
            }) or return $self->error( 500, {
                str  => 'failed to update a user info',
                data => {},
            });

            $guard->commit;
        }

        #
        # response
        #
        my %data = ( $user->user_info->get_columns, $user->get_columns );
        delete @data{qw/ user_id password /};

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_delete_user {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/ id /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('id')->required(1)->regexp(qr/^\d+$/);
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # find user
        #
        my $user = $DB->resultset('User')->find( \%params );
        return $self->error( 404, {
            str  => 'user not found',
            data => {},
        }) unless $user;

        #
        # delete & response
        #
        my %data = ( $user->user_info->get_columns, $user->get_columns );
        delete @data{qw/ user_id password /};
        $user->delete;

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_get_user_list {
        my $self = shift;
    }

    sub api_create_order {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/
            user_id     status_id     rental_date    target_date
            return_date return_method payment_method price
            discount    late_fee      l_discount     l_payment_method
            staff_name  comment       purpose        height
            weight      bust          waist          hip
            thigh       arm           leg            knee
            foot
        /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('user_id')->required(1)->regexp(qr/^\d+$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('User')->find({ id => $val });
            return ( 0, 'user not found using user_id' );
        });
        #
        # FIXME
        #   need more validation but not now
        #   since columns are not perfect yet.
        #
        $v->field(qw/ height weight bust waist hip thigh arm leg knee foot /)->each(sub {
            shift->regexp(qr/^\d{1,3}$/);
        });
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # create order
        #
        my $order = $DB->resultset('Order')->create( \%params );
        return $self->error( 500, {
            str  => 'failed to create a new order',
            data => {},
        }) unless $order;

        #
        # response
        #
        my %data = ( $order->get_columns );

        $self->res->headers->header(
            'Location' => $self->url_for( '/api/order/' . $order->id ),
        );
        $self->respond_to( json => { status => 201, json => \%data } );
    }

    sub api_get_order {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/ id /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('id')->required(1)->regexp(qr/^\d+$/);
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # find user
        #
        my $order = $DB->resultset('Order')->find( \%params );
        return $self->error( 404, {
            str  => 'order not found',
            data => {},
        }) unless $order;

        #
        # response
        #
        my %data = ( $order->get_columns );

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_update_order {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/
            id
            user_id     status_id     rental_date    target_date
            return_date return_method payment_method price
            discount    late_fee      l_discount     l_payment_method
            staff_name  comment       purpose        height
            weight      bust          waist          hip
            thigh       arm           leg            knee
            foot
        /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('id')->required(1)->regexp(qr/^\d+$/);
        $v->field('user_id')->regexp(qr/^\d+$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('User')->find({ id => $val });
            return ( 0, 'user not found using user_id' );
        });
        #
        # FIXME
        #   need more validation but not now
        #   since columns are not perfect yet.
        #
        $v->field(qw/ height weight bust waist hip thigh arm leg knee foot /)->each(sub {
            shift->regexp(qr/^\d{1,3}$/);
        });
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # find order
        #
        my $order = $DB->resultset('Order')->find({ id => $params{id} });
        return $self->error( 404, {
            str  => 'order not found',
            data => {},
        }) unless $order;

        #
        # update order
        #
        {
            my %_params = %params;
            delete $_params{id};
            $order->update( \%_params )
                or return $self->error( 500, {
                    str  => 'failed to update a order',
                    data => {},
                });
        }

        #
        # response
        #
        my %data = ( $order->get_columns );

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_delete_order {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/ id /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('id')->required(1)->regexp(qr/^\d+$/);
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # find order
        #
        my $order = $DB->resultset('Order')->find( \%params );
        return $self->error( 404, {
            str  => 'order not found',
            data => {},
        }) unless $order;

        #
        # delete & response
        #
        my %data = ( $order->get_columns );
        $order->delete;

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_get_order_list {
        my $self = shift;
    }

    sub api_create_clothes {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/
            arm   bust            category code
            color compatible_code gender   group_id
            hip   length          price    status_id
            thigh user_id         waist
        /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('code')->required(1)->regexp(qr/^[A-Z0-9]{4,5}$/);
        $v->field('category')->required(1)->in(@CATEGORIES);
        $v->field('gender')->in(qw/ male female /);
        $v->field('price')->regexp(qr/^\d*$/);
        $v->field(qw/ bust waist hip thigh arm length /)->each(sub {
            shift->regexp(qr/^\d{1,3}$/);
        });
        $v->field('user_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('User')->find({ id => $val });
            return ( 0, 'user not found using user_id' );
        });

        $v->field('status_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('Status')->find({ id => $val });
            return ( 0, 'status not found using status_id' );
        });

        $v->field('group_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('Group')->find({ id => $val });
            return ( 0, 'status not found using group_id' );
        });
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # adjust params
        #
        $params{code} = sprintf( '%05s', $params{code} ) if length( $params{code} ) == 4;

        #
        # create clothes
        #
        my $clothes = $DB->resultset('Clothes')->create( \%params );
        return $self->error( 500, {
            str  => 'failed to create a new clothes',
            data => {},
        }) unless $clothes;

        #
        # response
        #
        my %data = ( $clothes->get_columns );

        $self->res->headers->header(
            'Location' => $self->url_for( '/api/clothes/' . $clothes->code ),
        );
        $self->respond_to( json => { status => 201, json => \%data } );
    }

    sub api_get_clothes {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/ code /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('code')->required(1)->regexp(qr/^[A-Z0-9]{4,5}$/);
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # adjust params
        #
        $params{code} = sprintf( '%05s', $params{code} ) if length( $params{code} ) == 4;

        #
        # find clothes
        #
        my $clothes = $DB->resultset('Clothes')->find( \%params );
        return $self->error( 404, {
            str  => 'clothes not found',
            data => {},
        }) unless $clothes;

        #
        # additional information for clothes
        #
        my %extra_data;
        # '대여중'인 항목만 주문서 정보를 포함합니다.
        my $order = $clothes->orders->find({ status_id => 2 });
        if ($order) {
            %extra_data = (
                order => {
                    id          => $order->id,
                    price       => $order->price,
                    clothes     => [ $order->clothes->get_column('code')->all ],
                    late_fee    => $self->calc_late_fee( $order, 'commify' ),
                    overdue     => $self->calc_overdue( $order->target_date ),
                    rental_date => {
                        raw => $order->rental_date,
                        md  => $order->rental_date->month . '/' . $order->rental_date->day,
                        ymd => $order->rental_date->ymd
                    },
                    target_date => {
                        raw => $order->target_date,
                        md  => $order->target_date->month . '/' . $order->target_date->day,
                        ymd => $order->target_date->ymd
                    },
                },
            );
        }

        #
        # response
        #
        my %data = ( $clothes->get_columns, %extra_data );
        $data{status} = $clothes->status->name;

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_update_clothes {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/
            arm   bust            category code
            color compatible_code gender   group_id
            hip   length          price    status_id
            thigh user_id         waist
        /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('code')->required(1)->regexp(qr/^[A-Z0-9]{4,5}$/);
        $v->field('category')->in(@CATEGORIES);
        $v->field('gender')->in(qw/ male female unisex /);
        $v->field('price')->regexp(qr/^\d*$/);
        $v->field(qw/ bust waist hip thigh arm length /)->each(sub {
            shift->regexp(qr/^\d{1,3}$/);
        });
        $v->field('user_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('User')->find({ id => $val });
            return ( 0, 'user not found using user_id' );
        });

        $v->field('status_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('Status')->find({ id => $val });
            return ( 0, 'status not found using status_id' );
        });

        $v->field('group_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('Group')->find({ id => $val });
            return ( 0, 'status not found using group_id' );
        });
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # adjust params
        #
        $params{code} = sprintf( '%05s', $params{code} ) if length( $params{code} ) == 4;

        #
        # find clothes
        #
        my $clothes = $DB->resultset('Clothes')->find( \%params );
        return $self->error( 404, {
            str  => 'clothes not found',
            data => {},
        }) unless $clothes;

        #
        # update clothes
        #
        {
            my %_params = %params;
            delete $_params{code};
            $clothes->update( \%params )
                or return $self->error( 500, {
                    str  => 'failed to update a clothes',
                    data => {},
                });
        }

        #
        # response
        #
        my %data = ( $clothes->get_columns );

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_delete_clothes {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/ code /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('code')->required(1)->regexp(qr/^[A-Z0-9]{4,5}$/);
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # adjust params
        #
        $params{code} = sprintf( '%05s', $params{code} ) if length( $params{code} ) == 4;

        #
        # find clothes
        #
        my $clothes = $DB->resultset('Clothes')->find( \%params );
        return $self->error( 404, {
            str  => 'clothes not found',
            data => {},
        }) unless $clothes;

        #
        # delete & response
        #
        my %data = ( $clothes->get_columns );
        $clothes->delete;

        $self->respond_to( json => { status => 200, json => \%data } );
    }

    sub api_get_clothes_list {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/ code /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('code')->required(1)->regexp(qr/^[A-Z0-9]{4,5}$/);
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # adjust params
        #
        $params{code} = [ $params{code} ] unless ref $params{code} eq 'ARRAY';
        for my $code ( @{ $params{code} } ) {
            next unless length($code) == 4;
            $code = sprintf( '%05s', $code );
        }

        #
        # find clothes
        #
        my @clothes_list
                = $DB->resultset('Clothes')
                ->search( { code => $params{code} } )
                ->all
                ;
        return $self->error( 404, {
            str  => 'clothes list not found',
            data => {},
        }) unless @clothes_list;

        #
        # additional information for clothes list
        #
        my @data;
        for my $clothes (@clothes_list) {
            # '대여중'인 항목만 주문서 정보를 포함합니다.
            my %extra_data;
            my $order = $clothes->orders->find({ status_id => 2 });
            if ($order) {
                %extra_data = (
                    order => {
                        id          => $order->id,
                        price       => $order->price,
                        clothes     => [ $order->clothes->get_column('code')->all ],
                        late_fee    => $self->calc_late_fee( $order, 'commify' ),
                        overdue     => $self->calc_overdue( $order->target_date ),
                        rental_date => {
                            raw => $order->rental_date,
                            md  => $order->rental_date->month . '/' . $order->rental_date->day,
                            ymd => $order->rental_date->ymd
                        },
                        target_date => {
                            raw => $order->target_date,
                            md  => $order->target_date->month . '/' . $order->target_date->day,
                            ymd => $order->target_date->ymd
                        },
                    },
                );
            }
            push @data, {
                $clothes->get_columns,
                %extra_data,
                status => $clothes->status->name,
            };
        }

        #
        # response
        #
        $self->respond_to( json => { status => 200, json => \@data } );
    }

    sub api_update_clothes_list {
        my $self = shift;

        #
        # fetch params
        #
        my %params = $self->get_params(qw/
            arm   bust            category code
            color compatible_code gender   group_id
            hip   length          price    status_id
            thigh user_id         waist
        /);

        #
        # validate params
        #
        my $v = $self->create_validator;
        $v->field('code')->required(1)->regexp(qr/^[A-Z0-9]{4,5}$/);
        $v->field('category')->in(@CATEGORIES);
        $v->field('gender')->in(qw/ male female unisex /);
        $v->field('price')->regexp(qr/^\d*$/);
        $v->field(qw/ bust waist hip thigh arm length /)->each(sub {
            shift->regexp(qr/^\d{1,3}$/);
        });
        $v->field('user_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('User')->find({ id => $val });
            return ( 0, 'user not found using user_id' );
        });

        $v->field('status_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('Status')->find({ id => $val });
            return ( 0, 'status not found using status_id' );
        });

        $v->field('group_id')->regexp(qr/^\d*$/)->callback(sub {
            my $val = shift;

            return 1 if $DB->resultset('Group')->find({ id => $val });
            return ( 0, 'status not found using group_id' );
        });
        unless ( $self->validate( $v, \%params ) ) {
            my @error_str;
            while ( my ( $k, $v ) = each %{ $v->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, {
                str  => join(',', @error_str),
                data => $v->errors,
            });
        }

        #
        # adjust params
        #
        $params{code} = [ $params{code} ] unless ref $params{code} eq 'ARRAY';
        for my $code ( @{ $params{code} } ) {
            next unless length($code) == 4;
            $code = sprintf( '%05s', $code );
        }

        #
        # update clothes list
        #
        {
            my %_params = %params;
            my $code = delete $_params{code};
            $DB->resultset('Clothes')
                ->search( { code => $params{code} } )
                ->update( \%_params )
        }

        #
        # response
        #
        my %data = ();

        $self->respond_to( json => { status => 200, json => \%data } );
    }
}; # end of API section

get '/'      => 'home';
get '/login';

get '/new-borrower' => sub {
    my $self = shift;

    my $q  = $self->param('q') || q{};
    my $rs = $DB->resultset('User')->search(
        {
            -or => [
                'me.name'         => $q,
                'me.email'        => $q,
                'user_info.phone' => $q,
            ],
        },
        { join => 'user_info' },
    );

    my @users;
    while ( my $user = $rs->next ) {
        my %data = ( $user->user_info->get_columns, $user->get_columns );
        delete @data{qw/ user_id password /};
        push @users, \%data;
    }

    $self->respond_to(
        json => { json     => \@users        },
        html => { template => 'new-borrower' },
    );
};

post '/users' => sub {
    my $self = shift;

    my $validator = $self->user_validator;
    unless ($self->validate($validator)) {
        my @error_str;
        while ( my ($k, $v) = each %{ $validator->errors } ) {
            push @error_str, "$k:$v";
        }
        return $self->error( 400, { str => join(',', @error_str), data => $validator->errors } );
    }

    my $user = $self->create_user;
    return $self->error(500, 'failed to create a new user') unless $user;

    $self->res->headers->header('Location' => $self->url_for('/users/' . $user->id));
    $self->respond_to(
        json => { json => { $user->get_columns }, status => 201 },
        html => sub {
            $self->redirect_to('/users/' . $user->id);
        }
    );
};

any [qw/put patch/] => '/users/:id' => sub {
    my $self  = shift;

    my $validator = $self->user_validator;
    unless ($self->validate($validator)) {
        my @error_str;
        while ( my ($k, $v) = each %{ $validator->errors } ) {
            push @error_str, "$k:$v";
        }
        return $self->error( 400, { str => join(',', @error_str), data => $validator->errors } );
    }

    my $rs   = $DB->resultset('User');
    my $user = $rs->find({ id => $self->param('id') });
    map { $user->$_($self->param($_)) } qw/name phone gender age address/;
    $user->update;
    $self->respond_to(
        json => { json => { $user->get_columns } },
    );
};

post '/guests' => sub {
    my $self = shift;

    my $validator = $self->guest_validator;
    unless ( $self->validate($validator) ) {
        my @error_str;
        while ( my ( $k, $v ) = each %{ $validator->errors } ) {
            push @error_str, "$k:$v";
        }
        return $self->error( 400, { str => join( ',', @error_str ), data => $validator->errors } );
    }

    return $self->error(400, 'invalid request') unless $self->param('user_id');

    my $user = $DB->resultset('User')->find({ id => $self->param('user_id') });
    return $self->error(404, 'not found user') unless $user;

    $user->user_info->update({
        map {
            defined $self->param($_) ? ( $_ => $self->param($_) ) : ()
        } qw( height weight bust waist hip thigh arm leg knee foot )
    });

    my %data = ( $user->user_info->get_columns, $user->get_columns );
    delete @data{qw/ user_id password /};

    $self->res->headers->header( 'Location' => $self->url_for( '/guests/' . $user->id ) );
    $self->respond_to(
        json => { json => \%data, status => 201 },
        html => sub { $self->redirect_to( '/guests/' . $user->id ) },
    );
};

get '/guests/:id' => sub {
    my $self = shift;

    my $user = $DB->resultset('User')->find({ id => $self->param('id') });
    return $self->error(404, 'not found user') unless $user;

    my @orders = $DB->resultset('Order')->search(
        { guest_id => $self->param('id') },
        { order_by => { -desc => 'rental_date' } },
    );

    $self->stash(
        user   => $user,
        orders => \@orders,
    );

    my %data = ( $user->user_info->get_columns, $user->get_columns );
    delete @data{qw/ user_id password /};

    $self->respond_to(
        json => { json     => \%data      },
        html => { template => 'guests/id' },
    );
};

any [qw/put patch/] => '/guests/:id' => sub {
    my $self  = shift;

    my $validator = $self->guest_validator;
    unless ($self->validate($validator)) {
        my @error_str;
        while ( my ($k, $v) = each %{ $validator->errors } ) {
            push @error_str, "$k:$v";
        }
        return $self->error( 400, { str => join(',', @error_str), data => $validator->errors } );
    }

    my $user = $DB->resultset('User')->find({ id => $self->param('user_id') });
    return $self->error(404, 'not found user') unless $user;

    $user->user_info->update({
        map {
            defined $self->param($_) ? ( $_ => $self->param($_) ) : ()
        } qw( height weight bust waist hip thigh arm leg knee foot )
    });

    my %data = ( $user->user_info->get_columns, $user->get_columns );
    delete @data{qw/ user_id password /};

    $self->respond_to( json => { json => \%data } );
};

post '/clothes' => sub {
    my $self = shift;

    my $validator  = $self->cloth_validator;
    my @cloth_list = $self->param('clothes-list');

    ###
    ### validate
    ###
    for my $clothes (@cloth_list) {
        my (
            $donor_id, $category, $color, $bust,
            $waist,    $hip,      $arm,   $thigh,
            $length,   $gender,   $compatible_code,
        ) = split /-/, $clothes;

        my $is_valid = $self->validate($validator, {
            category        => $category,
            color           => $color,
            bust            => $bust,
            waist           => $waist,
            hip             => $hip,
            arm             => $arm,
            thigh           => $thigh,
            length          => $length,
            gender          => $gender || 1,    # TODO: should get from params
            compatible_code => $compatible_code,
        });

        unless ($is_valid) {
            my @error_str;
            while ( my ($k, $v) = each %{ $validator->errors } ) {
                push @error_str, "$k:$v";
            }
            return $self->error( 400, { str => join(',', @error_str), data => $validator->errors } );
        }
    }

    ###
    ### create
    ###
    my @clothes_list;
    for my $clothes (@cloth_list) {
        my (
            $donor_id, $category, $color, $bust,
            $waist,    $hip,      $arm,   $thigh,
            $length,   $gender,   $compatible_code,
        ) = split /-/, $clothes;

        my %cloth_info = (
            color           => $color,
            bust            => $bust,
            waist           => $waist,
            hip             => $hip,
            arm             => $arm,
            thigh           => $thigh,
            length          => $length,
            gender          => $gender || 1,    # TODO: should get from params
            compatible_code => $compatible_code,
        );

        #
        # TRANSACTION
        #
        my $guard = $DB->txn_scope_guard;
        if ( $category =~ m/jacket/ && $category =~ m/pants/ ) {
            my $c1 = $self->create_cloth( %cloth_info, category => 'jacket' );
            my $c2 = $self->create_cloth( %cloth_info, category => 'pants'  );
            return $self->error(500, '!!! failed to create a new clothes') unless ($c1 && $c2);

            if ($donor_id) {
                $c1->create_related('donor_cloths', { donor_id => $donor_id });
                $c2->create_related('donor_cloths', { donor_id => $donor_id });
            }

            $c1->bottom_id($c2->id);
            $c2->top_id($c1->id);
            $c1->update;
            $c2->update;

            push @clothes_list, $c1, $c2;
        }
        elsif ( $category =~ m/jacket/ && $category =~ m/skirt/ ) {
            my $c1 = $self->create_cloth( %cloth_info, category => 'jacket' );
            my $c2 = $self->create_cloth( %cloth_info, category => 'skirt'  );
            return $self->error(500, '!!! failed to create a new clothes') unless ($c1 && $c2);

            if ($donor_id) {
                $c1->create_related('donor_cloths', { donor_id => $donor_id });
                $c2->create_related('donor_cloths', { donor_id => $donor_id });
            }

            $c1->bottom_id($c2->id);
            $c2->top_id($c1->id);
            $c1->update;
            $c2->update;

            push @clothes_list, $c1, $c2;
        } else {
            my $c = $self->create_cloth(%cloth_info);
            return $self->error(500, '--- failed to create a new clothes') unless $c;

            if ($donor_id) {
                $c->create_related('donor_cloths', { donor_id => $donor_id });
            }
            push @clothes_list, $c;
        }
        $guard->commit;
    }

    ###
    ### response
    ###
    ## 여러개가 될 수 있으므로 Location 헤더는 생략
    ## $self->res->headers->header('Location' => $self->url_for('/clothes/' . $clothes->code));
    $self->respond_to(
        json => { json => [map { $self->cloth2hr($_) } @clothes_list], status => 201 },
        html => sub {
            $self->redirect_to('/clothes');
        }
    );
};

put '/clothes' => sub {
    my $self = shift;

    my $clothes_list = $self->param('clothes_list');
    return $self->error(400, 'Nothing to change') unless $clothes_list;

    my $status = $DB->resultset('Status')->find({ name => $self->param('status') });
    return $self->error(400, 'Invalid status') unless $status;

    my $rs    = $DB->resultset('Clothes')->search({ 'me.id' => { -in => [split(/,/, $clothes_list)] } });
    my $guard = $DB->txn_scope_guard;
    my @rows;
    # BEGIN TRANSACTION ~
    while (my $clothes = $rs->next) {
        $clothes->status_id($status->id);
        $clothes->update;
        push @rows, { $clothes->get_columns };
    }
    # ~ COMMIT
    $guard->commit;

    $self->respond_to(
        json => { json => [@rows] },
        html => { template => 'clothes' }    # TODO: `clothes.html.haml`
    );
};

get '/new-clothes' => sub {
    my $self = shift;

    my $q  = $self->param('q') || q{};
    my $rs = $DB->resultset('User')->search({
        -or => [
            id    => $q,
            name  => $q,
            phone => $q,
            email => $q,
        ],
    });

    my @users;
    while ( my $user = $rs->next ) {
        my %data = ( $user->user_info->get_columns, $user->get_columns );
        delete @data{qw/ user_id password height weight bust waist hip thigh arm leg knee foot /};
        push @users, \%data;
    }

    $self->respond_to(
        json => { json     => \@users     },
        html => { template => 'new-clothes' },
    );
};


get '/clothes/:code' => sub {
    my $self = shift;
    my $code = $self->param('code');
    my $clothes = $DB->resultset('Clothes')->find({ code => $code });
    return $self->error(404, "Not found `$code`") unless $clothes;

    my $co_rs = $clothes->cloth_orders->search({
        'order.status_id' => { -in => [$Opencloset::Constant::STATUS_RENT, $clothes->status_id] },
    }, {
        join => 'order'
    })->next;

    unless ($co_rs) {
        $self->respond_to(
            json => { json => $self->cloth2hr($clothes) },
            html => { template => 'clothes/code', clothes => $clothes }    # also, CODEREF is OK
        );
        return;
    }

    my @with;
    my $order = $co_rs->order;
    for my $_cloth ($order->cloths) {
        next if $_cloth->id == $clothes->id;
        push @with, $self->cloth2hr($_cloth);
    }

    my $overdue = $self->calc_overdue($order->target_date, DateTime->now);
    my %columns = (
        %{ $self->cloth2hr($clothes) },
        rental_date => {
            raw => $order->rental_date,
            md  => $order->rental_date->month . '/' . $order->rental_date->day,
            ymd => $order->rental_date->ymd
        },
        target_date => {
            raw => $order->target_date,
            md  => $order->target_date->month . '/' . $order->target_date->day,
            ymd => $order->target_date->ymd
        },
        order_id    => $order->id,
        price       => $self->commify($order->price),
        overdue     => $overdue,
        late_fee    => $self->calc_late_fee( $order, 'commify' ),
        clothes     => \@with,
    );

    $self->respond_to(
        json => { json => { %columns } },
        html => { template => 'clothes/code', clothes => $clothes }    # also, CODEREF is OK
    );
};

any [qw/put patch/] => '/clothes/:code' => sub {
    my $self = shift;
    my $code = $self->param('code');
    my $clothes = $DB->resultset('Clothes')->find({ code => $code });
    return $self->error(404, "Not found `$code`") unless $clothes;

    map {
        $clothes->$_($self->param($_)) if defined $self->param($_);
    } qw/bust waist arm length/;

    $clothes->update;
    $self->respond_to(
        json => { json => $self->cloth2hr($clothes) },
        html => { template => 'clothes/code', clothes => $clothes }    # also, CODEREF is OK
    );
};

get '/search' => sub {
    my $self = shift;

    my $q                = $self->param('q')                || q{};
    my $gid              = $self->param('gid')              || q{};
    my $color            = $self->param('color')            || q{};
    my $entries_per_page = $self->param('entries_per_page') || app->config->{entries_per_page};

    my $user = $gid ? $DB->resultset('User')->find({ id => $gid }) : undef;
    my ( $bust, $waist, $arm, $status_id, $category ) = split /\//, $q;
    $status_id ||= 0;
    $category  ||= 'jacket';

    my %cond;
    $cond{'me.category'}  = $category;
    $cond{'me.bust'}      = { '>=' => $bust  } if $bust;
    $cond{'bottom.waist'} = { '>=' => $waist } if $waist;
    $cond{'me.arm'}       = { '>=' => $arm   } if $arm;
    $cond{'me.status_id'} = $status_id         if $status_id;
    $cond{'me.color'}     = $color             if $color;

    ### row, current_page, count
    my $clothes_list = $DB->resultset('Clothes')->search(
        \%cond,
        {
            page     => $self->param('p') || 1,
            rows     => $entries_per_page,
            order_by => [qw/bust bottom.waist arm/],
            join     => 'bottom',
        }
    );

    my $pageset = Data::Pageset->new({
        total_entries    => $clothes_list->pager->total_entries,
        entries_per_page => $entries_per_page,
        current_page     => $self->param('p') || 1,
        mode             => 'fixed'
    });

    $self->stash(
        q            => $q,
        gid          => $gid,
        user         => $user,
        clothes_list => $clothes_list,
        pageset      => $pageset,
        status_id    => $status_id,
        category     => $category,
        color        => $color,
    );
};

get '/rental' => sub {
    my $self = shift;

    my $today = DateTime->now;
    $today->set_hour(0);
    $today->set_minute(0);
    $today->set_second(0);

    my $q     = $self->param('q');
    my @users = $DB->resultset('User')->search(
        {
            -or => [
                'id'              => $q,
                'name'            => $q,
                'email'           => $q,
                'user_info.phone' => $q,
            ],
        },
        { join => 'user_info' },
    );

    ### DBIx::Class::Storage::DBI::_gen_sql_bind(): DateTime objects passed to search() are not
    ### supported properly (InflateColumn::DateTime formats and settings are not respected.)
    ### See "Formatting DateTime objects in queries" in DBIx::Class::Manual::Cookbook.
    ### To disable this warning for good set $ENV{DBIC_DT_SEARCH_OK} to true
    ###
    ### DateTime object 를 search 에 바로 사용하지 말고 parser 를 이용하라능 - @aanoaa
    my $dt_parser = $DB->storage->datetime_parser;
    push @users, $DB->resultset('User')->search(
        {
            -or => [
                create_date => { '>=' => $dt_parser->format_datetime($today) },
                visit_date  => { '>=' => $dt_parser->format_datetime($today) },
            ],
        },
        { order_by => { -desc => 'create_date' } },
    );

    $self->stash( users => \@users );
} => 'rental';

post '/orders' => sub {
    my $self = shift;

    my $validator = $self->create_validator;
    $validator->field([qw/gid clothes-id/])
        ->each(sub { shift->required(1)->regexp(qr/^\d+$/) });

    return $self->error(400, 'failed to validate')
        unless $self->validate($validator);

    my $user         = $DB->resultset('User')->find({ id => $self->param('gid') });
    my @clothes_list = $DB->resultset('Clothes')->search({ 'me.id' => { -in => [$self->param('clothes-id')] } });

    return $self->error(400, 'invalid request') unless $user || @clothes_list;

    my $guard = $DB->txn_scope_guard;
    my $order;
    try {
        # BEGIN TRANSACTION ~
        $order = $DB->resultset('Order')->create({
            user_id  => $user->id,
            bust     => $user->user_info->bust,
            waist    => $user->user_info->waist,
            arm      => $user->user_info->arm,
            leg      => $user->user_info->leg,
            purpose  => $user->purpose,
        });

        for my $clothes (@clothes_list) {
            $order->create_related('cloth_orders', { cloth_id => $clothes->id });
        }
        # FIXME now user does not have visit_date column
        #my $dt_parser = $DB->storage->datetime_parser;
        #$user->visit_date($dt_parser->format_datetime(DateTime->now()));
        #$user->update;    # refresh `visit_date`
        $guard->commit;
        # ~ COMMIT
    } catch {
        # ROLLBACK
        my $error = shift;
        $self->app->log->error("Failed to create `order`: $error");
        return $self->error(500, "Failed to create `order`: $error") unless $order;
    };

    $self->res->headers->header('Location' => $self->url_for('/orders/' . $order->id));
    $self->respond_to(
        json => { json => $self->order2hr($order), status => 201 },
        html => sub {
            $self->redirect_to('/orders/' . $order->id);
        }
    );
};

get '/orders' => sub {
    my $self = shift;

    my $q      = $self->param('q') || '';
    my $cond;
    $cond->{status_id} = $q if $q;
    my $orders = $DB->resultset('Order')->search($cond);

    $self->stash( orders => $orders );
} => 'orders';

get '/orders/:id' => sub {
    my $self = shift;

    my $order = $DB->resultset('Order')->find({ id => $self->param('id') });
    return $self->error(404, "Not found") unless $order;

    my @clothes_list = $order->cloths;
    my $price = 0;
    for my $clothes (@clothes_list) {
        $price += $clothes->price;
    }

    my $overdue  = $self->calc_overdue($order->target_date);
    my $late_fee = $self->calc_late_fee($order);

    my $clothes = $order->cloths({ category => 'jacket' })->next;

    my $satisfaction;
    if ($clothes) {
        $satisfaction = $clothes->satisfactions({
            cloth_id => $clothes->id,
            guest_id  => $order->guest->id,
        })->next;
    }

    $self->stash(
        order        => $order,
        clothes      => \@clothes_list,
        price        => $price,
        overdue      => $overdue,
        late_fee     => $late_fee,
        satisfaction => $satisfaction,
    );

    my %fillinform = $order->get_columns;
    $fillinform{price} = $price unless $fillinform{price};
    $fillinform{late_fee} = $late_fee;
    unless ($fillinform{target_date}) {
        $fillinform{target_date} = DateTime->now()->add(days => 3)->ymd;
    }

    my $status_id = $order->status ? $order->status->id : undef;
    if ($status_id) {
        if ($status_id == $Opencloset::Constant::STATUS_RENT) {
            $self->stash(template => 'orders/id/status_rent');
        } elsif ($status_id == $Opencloset::Constant::STATUS_RETURN) {
            $self->stash(template => 'orders/id/status_return');
        } elsif ($status_id == $Opencloset::Constant::STATUS_PARTIAL_RETURN) {
            $self->stash(template => 'orders/id/status_partial_return');
        }
    } else {
        $self->stash(template => 'orders/id/nil_status');
    }

    map { delete $fillinform{$_} } qw/bust waist arm length/;
    $self->render_fillinform({ %fillinform });
};

any [qw/post put patch/] => '/orders/:id' => sub {
    my $self = shift;

    # repeat codes; use `under`?
    my $order = $DB->resultset('Order')->find({ id => $self->param('id') });
    return $self->error(404, "Not found") unless $order;

    my $validator = $self->create_validator;
    unless ($order->status_id) {
        $validator->field('target_date')->required(1);
        $validator->field('payment_method')->required(1);
    }
    if ($order->status_id && $order->status_id == $Opencloset::Constant::STATUS_RENT) {
        $validator->field('return_method')->required(1);
    }
    $validator->field([qw/price discount late_fee l_discount/])
        ->each(sub { shift->regexp(qr/^\d+$/) });
    $validator->field([qw/bust waist arm top_fit bottom_fit/])
        ->each(sub { shift->regexp(qr/^[12345]$/) });

    return $self->error(400, 'failed to validate')
        unless $self->validate($validator);

    ## Note: target_date INSERT as string likes '2013-01-01',
    ##       maybe should convert to DateTime object
    map {
        $order->$_($self->param($_)) if defined $self->param($_);
    } qw/price discount target_date comment return_method late_fee l_discount payment_method staff_name/;
    my %status_to_be = (
        0 => $Opencloset::Constant::STATUS_RENT,
        $Opencloset::Constant::STATUS_RENT => $Opencloset::Constant::STATUS_RETURN,
        $Opencloset::Constant::STATUS_PARTIAL_RETURN => $Opencloset::Constant::STATUS_RETURN,
    );

    my $guard = $DB->txn_scope_guard;
    # BEGIN TRANSACTION ~
    my $status_id = $status_to_be{$order->status_id || 0};
    my @missing_clothes_list;
    if ($status_id == $Opencloset::Constant::STATUS_RETURN) {
        my $missing_clothes_list = $self->param('missing_clothes_list') || '';
        if ($missing_clothes_list) {
            $status_id = $Opencloset::Constant::STATUS_PARTIAL_RETURN;
            @missing_clothes_list = $DB->resultset('Clothes')->search({
                'me.code' => { -in => [split(/,/, $missing_clothes_list)] }
            });
        }
    }

    $order->status_id($status_id);
    my $dt_parser = $DB->storage->datetime_parser;
    if ($status_id == $Opencloset::Constant::STATUS_RETURN ||
            $status_id == $Opencloset::Constant::STATUS_PARTIAL_RETURN) {
        $order->return_date($dt_parser->format_datetime(DateTime->now()));
    }
    $order->rental_date($dt_parser->format_datetime(DateTime->now))
        if $status_id == $Opencloset::Constant::STATUS_RENT;
    $order->update;

    for my $clothes ($order->cloths) {
        if ($order->status_id == $Opencloset::Constant::STATUS_RENT) {
            $clothes->status_id($Opencloset::Constant::STATUS_RENT);
        }
        else {
            next if grep { $clothes->id == $_->id } @missing_clothes_list;

            no warnings 'experimental';
            given ( $clothes->category ) {
                when ( /^(shoes|tie|hat)$/i ) {
                    $clothes->status_id($Opencloset::Constant::STATUS_AVAILABLE);    # Shoes, Tie, Hat
                }
                default {
                    if ($clothes->status_id != $Opencloset::Constant::STATUS_AVAILABLE) {
                        $clothes->status_id($Opencloset::Constant::STATUS_WASHING);
                    }
                }
            }
        }
        $clothes->update;
    }

    for my $clothes (@missing_clothes_list) {
        $clothes->status_id($Opencloset::Constant::STATUS_PARTIAL_RETURN);
        $clothes->update;
    }
    $guard->commit;
    # ~ COMMIT

    my %satisfaction;
    map { $satisfaction{$_} = $self->param($_) } qw/bust waist arm top_fit bottom_fit/;

    if (values %satisfaction) {
        # $order
        my $clothes = $order->cloths({ category => 'jacket' })->next;
        if ($clothes) {
            $DB->resultset('Satisfaction')->update_or_create({
                %satisfaction,
                guest_id  => $order->guest_id,
                cloth_id => $clothes->id,
            });
        }
    }

    $self->respond_to(
        json => { json => $self->order2hr($order) },
        html => sub {
            $self->redirect_to($self->url_for);
        }
    );
};

del '/orders/:id' => sub {
    my $self = shift;

    my $order = $DB->resultset('Order')->find({ id => $self->param('id') });
    return $self->error(404, "Not found") unless $order;

    for my $clothes ($order->cloths) {
        $clothes->status_id($Opencloset::Constant::STATUS_AVAILABLE);
        $clothes->update;
    }

    $order->delete;

    $self->respond_to(
        json => { json => {} },    # just 200 OK
    );
};

post '/donors' => sub {
    my $self   = shift;

    my $user = $DB->resultset('User')->find({ id => $self->param('user_id') });
    return $self->error(404, 'not found user') unless $user;

    $user->user_info->update({
        map {
            defined $self->param($_) ? ( $_ => $self->param($_) ) : ()
        } qw()
    });

    my %data = ( $user->user_info->get_columns, $user->get_columns );
    delete @data{qw/ user_id password /};

    $self->res->headers->header('Location' => $self->url_for('/donors/' . $user->id));
    $self->respond_to(
        json => { json => \%data, status => 201                  },
        html => sub { $self->redirect_to('/donors/' . $user->id) },
    );
};

any [qw/put patch/] => '/donors/:id' => sub {
    my $self  = shift;

    my $user = $DB->resultset('User')->find({ id => $self->param('id') });
    return $self->error(404, 'not found user') unless $user;

    $user->user_info->update({
        map {
            defined $self->param($_) ? ( $_ => $self->param($_) ) : ()
        } qw()
    });

    my %data = ( $user->user_info->get_columns, $user->get_columns );
    delete @data{qw/ user_id password /};

    $self->respond_to( json => { json => \%data } );
};

post '/sms' => sub {
    my $self = shift;

    my $validator = $self->create_validator;
    $validator->field('to')->required(1)->regexp(qr/^0\d{9,10}$/);
    return $self->error(400, 'Bad receipent') unless $self->validate($validator);

    my $to     = $self->param('to');
    my $from   = app->config->{sms}{sender};
    my $text   = app->config->{sms}{text};
    my $sender = SMS::Send->new(
        'KR::CoolSMS',
        _ssl      => 1,
        _user     => app->config->{sms}{username},
        _password => app->config->{sms}{password},
        _type     => 'sms',
        _from     => $from,
    );

    my $sent = $sender->send_sms(
        text => $text,
        to   => $to,
    );

    return $self->error(500, $sent->{reason}) unless $sent;

    my $sms = $DB->resultset('ShortMessage')->create({
        from => $from,
        to   => $to,
        msg  => $text,
    });

    $self->res->headers->header('Location' => $self->url_for('/sms/' . $sms->id));
    $self->respond_to(
        json => { json => { $sms->get_columns }, status => 201 },
        html => sub {
            $self->redirect_to('/sms/' . $sms->id);    # TODO: GET /sms/:id
        }
    );
};

app->secret( app->defaults->{secret} );
app->start;

__DATA__

@@ login.html.haml
- my $id = 'login';
- layout 'login', active_id => $id;
- title $sidebar->{meta}{login}{text};


@@ home.html.haml
- my $id   = 'home';
- my $meta = $sidebar->{meta};
- layout 'default', active_id => $id;
- title $meta->{$id}{text};

.search
  %form#clothes-search-form
    .input-group
      %input#clothes-id.form-control{ :type => 'text', :placeholder => '품번' }
      %span.input-group-btn
        %button#btn-clothes-search.btn.btn-sm.btn-default{ :type => 'button' }
          %i.icon-search.bigger-110 검색
      %span.input-group-btn
        %button#btn-clear.btn.btn.btn-sm.btn-default{:type => 'button'}
          %i.icon-eraser.bigger-110 지우기

.space-8

#clothes-table
  %table.table.table-striped.table-bordered.table-hover
    %thead
      %tr
        %th.center
          %label
            %input#input-check-all.ace{ :type => 'checkbox' }
            %span.lbl
        %th 옷
        %th 상태
        %th 묶음
        %th 기타
    %tbody
  %ul
  #action-buttons.btn-group
    %button.btn.btn-primary.dropdown-toggle{ 'data-toggle' => 'dropdown' }
      선택한 항목을 변경할 상태를 선택하세요.
      %i.icon-angle-down.icon-on-right
    %ul.dropdown-menu
      - for my $status (qw/ 세탁 대여가능 /) {
        %li
          %a{ :href => "#" }= $status
      - }
      %li.divider
      - for my $status (qw/ 대여불가 예약 수선 분실 폐기 /) {
        %li
          %a{ :href => "#" }= $status
      - }

:plain
  <script id="tpl-row-checkbox-clothes-with-order" type="text/html">
    <tr data-order-id="<%= order.id %>">
      <td class="center">
        <label>
          <input class="ace" type="checkbox" disabled>
          <span class="lbl"></span>
        </label>
      </td>
      <td> <a href="/clothes/<%= code %>"> <%= code %> </a> </td> <!-- 옷 -->
      <td>
        <span class="order-status label">
          <%= status %>
          <span class="late-fee"><%= order.late_fee ? order.late_fee + '원' : '' %></span>
        </span>
      </td> <!-- 상태 -->
      <td>
        <% _.each(order.clothes, function(c) { c = c.replace(/^0/, ''); %> <a href="/clothes/<%= c %>"><%= c %></a><% }); %>
      </td> <!-- 묶음 -->
      <td>
        <a href="/orders/<%= order.id %>"><span class="label label-info arrowed-right arrowed-in">
          <strong>주문서</strong>
          <time class="js-relative-date" datetime="<%= order.rental_date.raw %>" title="<%= order.rental_date.ymd %>"><%= order.rental_date.md %></time>
          ~
          <time class="js-relative-date" datetime="<%= order.target_date.raw %>" title="<%= order.target_date.ymd %>"><%= order.target_date.md %></time>
        </span></a>
      </td> <!-- 기타 -->
    </tr>
  </script>

:plain
  <script id="tpl-row-checkbox-clothes" type="text/html">
    <tr class="row-checkbox" data-clothes-code="<%= code %>">
      <td class="center">
        <label>
          <input class="ace" type="checkbox" <%= status == '대여중' ? 'disabled' : '' %> data-clothes-code="<%= code %>">
          <span class="lbl"></span>
        </label>
      </td>
      <td> <a href="/clothes/<%= code %>"> <%= code %> </a> </td> <!-- 옷 -->
      <td> <span class="order-status label"><%= status %></span> </td> <!-- 상태 -->
      <td> </td> <!-- 묶음 -->
      <td> </td> <!-- 기타 -->
    </tr>
  </script>

:plain
  <script id="tpl-overdue-paragraph" type="text/html">
    <span>
      연체료 <%= order.late_fee %>원 = <%= order.price %>원 x <%= order.overdue %>일 x 20%
    </span>
  </script>


@@ new-borrower.html.haml
- my $id   = 'new-borrower';
- my $meta = $sidebar->{meta};
- layout 'default',
-   active_id   => $id,
-   breadcrumbs => [
-     { text => $meta->{$id}{text} },
-   ],
-   jses => ['/lib/bootstrap/js/fuelux/fuelux.wizard.min.js'];
- title $meta->{$id}{text};

#new-borrower
  .row-fluid
    .span12
      .widget-box
        .widget-header.widget-header-blue.widget-header-flat
          %h4.lighter 대여자 등록

        .widget-body
          .widget-main
            /
            / step navigation
            /
            #fuelux-wizard.row-fluid{ "data-target" => '#step-container' }
              %ul.wizard-steps
                %li.active{ "data-target" => "#step1" }
                  %span.step  1
                  %span.title 대여자 검색
                %li{ "data-target" => "#step2" }
                  %span.step  2
                  %span.title 개인 정보 및 대여 목적
                %li{ "data-target" => "#step3" }
                  %span.step  3
                  %span.title 신체 치수
                %li{ "data-target" => "#step4" }
                  %span.step  4
                  %span.title 완료

            %hr

            #step-container.step-content.row-fluid.position-relative
              /
              / step1
              /
              #step1.step-pane.active
                %h3.lighter.block.green 이전에 방문했던 적이 있나요?
                .form-horizontal
                  /
                  / 대여자 검색
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3 대여자 검색:
                    .col-xs-12.col-sm-9
                      .search
                        .input-group
                          %input#guest-search.form-control{ :name => 'guest-search' :type => 'text', :placeholder => '이름 또는 이메일, 휴대전화 번호' }
                          %span.input-group-btn
                            %button#btn-guest-search.btn.btn-default.btn-sm{ :type => 'submit' }
                              %i.icon-search.bigger-110 검색
                  /
                  / 대여자 선택
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3 대여자 선택:
                    .col-xs-12.col-sm-9
                      #guest-search-list
                        %div
                          %label.blue
                            %input.ace.valid{ :name => 'user-id', :type => 'radio', :value => '0' }
                            %span.lbl= ' 처음 방문했습니다.'
                      :plain
                        <script id="tpl-new-borrower-guest-id" type="text/html">
                          <div>
                            <label class="blue highlight">
                              <input type="radio" class="ace valid" name="user-id" value="<%= user_id %>" data-user-id="<%= user_id %>" data-guest-id="<%= id %>">
                              <span class="lbl"> <%= name %> (<%= email %>)</span>
                              <span><%= address %></span>
                            </label>
                          </div>
                        </script>

                  .hr.hr-dotted

                %form.form-horizontal{ :method => "get" }
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3
                    .col-xs-12.col-sm-9
                      %div
                        :plain
                          <strong class="co-name">#{$company_name}</strong>은 정확한 의류 선택 및
                          대여 관리를 위해 개인 정보와 신체 치수를 수집합니다.
                          수집한 정보는 <strong class="co-name">#{$company_name}</strong>의
                          대여 서비스 품질을 높이기 위한 통계 목적으로만 사용합니다.

                      .space-8

                      %div
                        :plain
                          <strong class="co-name">#{$company_name}</strong>은 대여자의 반납 편의를 돕거나
                          <strong class="co-name">#{$company_name}</strong> 관련 유용한 정보를 알려드리기 위해
                          기재된 연락처로 휴대폰 단문 메시지 또는 전자우편을 보내거나 전화를 드립니다.
              /
              / step2
              /
              #step2.step-pane
                %h3.lighter.block.green 다음 개인 정보를 입력해주세요.
                %form.form-horizontal{ :method => 'get' }
                  /
                  / 전자우편
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'email' } 전자우편:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#email.valid.col-xs-12.col-sm-6{ :name => 'email', :type => 'text' }

                  /
                  / 이름
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'name' } 이름:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#name.valid.col-xs-12.col-sm-6{ :name => 'name', :type => 'text' }

                  /
                  / 나이
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'age' } 나이:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#age.valid.col-xs-12.col-sm-6{ :name => 'age', :type => 'text' }

                  /
                  / 성별
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3 성별:
                    .col-xs-12.col-sm-9
                      %div
                        %label.blue
                          %input.ace.valid{ :type => 'radio', :name => 'gender', :value => '1' }
                          %span.lbl= " 남자"
                      %div
                        %label.blue
                          %input.ace.valid{ :type => 'radio', :name => 'gender', :value => '2' }
                          %span.lbl= " 여자"

                  /
                  / 휴대전화
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'phone' } 휴대전화:
                    .col-xs-12.col-sm-7
                      .input-group
                        %input#phone.form-control.valid.col-xs-12.col-sm-6{ :name => 'phone', :type => 'tel' }
                        %span.input-group-btn
                          %button#btn-sendsms.btn.btn-sm.btn-default
                            %i.icon-phone
                            인증

                  /
                  / 주소
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'address' } 주소:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#address.valid.col-xs-12.col-sm-9{ :name => 'address', :type => 'text' }

                  .hr.hr-dotted

                  /
                  / 키
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'height' } 키:
                    .col-xs-12.col-sm-5
                      .input-group
                        %input#height.form-control.valid.col-xs-12.col-sm-6{ :name => 'height', :type => 'text' }
                        %span.input-group-addon
                          %i cm

                  /
                  / 몸무게
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'weight' } 몸무게:
                    .col-xs-12.col-sm-5
                      .input-group
                        %input#weight.form-control.valid.col-xs-12.col-sm-6{ :name => 'weight', :type => 'text' }
                        %span.input-group-addon
                          %i kg

                  .hr.hr-dotted

                  /
                  / 대여 목적
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'purpose' } 대여 목적:
                    .col-xs-12.col-sm-7
                      .guest-why
                        %input#purpose.valid.col-xs-12.col-sm-6{ :name => 'purpose', :type => 'text', :value => '', :placeholder => '대여목적', 'data-provide' => 'tag' }
                        %p
                          %span.label.label-info.clickable 입사면접
                          %span.label.label-info.clickable 사진촬영
                          %span.label.label-info.clickable 결혼식
                          %span.label.label-info.clickable 장례식
                          %span.label.label-info.clickable 입학식
                          %span.label.label-info.clickable 졸업식
                          %span.label.label-info.clickable 세미나
                          %span.label.label-info.clickable 발표

                  /
                  / 응시 기업 및 분야
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'domain' } 응시 기업 및 분야:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#domain.valid.col-xs-12.col-sm-6{ :name => 'domain', :type => 'text' }

              /
              / step3
              /
              #step3.step-pane
                %h3.lighter.block.green 다음 신체 치수를 입력해주세요.
                %form.form-horizontal{ :method => 'get' }
                  /
                  / 가슴
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'bust' } 가슴:
                    .col-xs-12.col-sm-5
                      .input-group
                        %input#bust.form-control.valid.col-xs-12.col-sm-6{ :name => 'bust', :type => 'text' }
                        %span.input-group-addon
                          %i cm

                  /
                  / 허리
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'waist' } 허리:
                    .col-xs-12.col-sm-5
                      .input-group
                        %input#waist.form-control.valid.col-xs-12.col-sm-6{ :name => 'waist', :type => 'text' }
                        %span.input-group-addon
                          %i cm

                  /
                  / 엉덩이
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'hip' } 엉덩이:
                    .col-xs-12.col-sm-5
                      .input-group
                        %input#hip.form-control.valid.col-xs-12.col-sm-6{ :name => 'hip', :type => 'text' }
                        %span.input-group-addon
                          %i cm

                  /
                  / 팔 길이
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'arm' } 팔 길이:
                    .col-xs-12.col-sm-5
                      .input-group
                        %input#arm.form-control.valid.col-xs-12.col-sm-6{ :name => 'arm', :type => 'text' }
                        %span.input-group-addon
                          %i cm

                  /
                  / 다리 길이
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'length' } 다리 길이:
                    .col-xs-12.col-sm-5
                      .input-group
                        %input#length.form-control.valid.col-xs-12.col-sm-6{ :name => 'length', :type => 'text' }
                        %span.input-group-addon
                          %i cm

              /
              / step4
              /
              #step4.step-pane
                %h3.lighter.block.green 등록이 완료되었습니다!

            %hr

            .wizard-actions.row-fluid
              %button.btn.btn-prev{ :disabled => "disabled" }
                %i.icon-arrow-left
                이전
              %button.btn.btn-next.btn-success{ "data-last" => "완료 " }
                다음
                %i.icon-arrow-right.icon-on-right


@@ guests/status.html.haml
%ul
  %li
    %i.icon-user
    %a{:href => "#{url_for('/guests/' . $user->id)}"} #{$user->name}
    %span (#{$user->user_info->birth})
  %li
    %i.icon-map-marker
    = $user->user_info->address
  %li
    %i.icon-envelope
    %a{:href => "mailto:#{$user->email}"}= $user->email
  %li= $user->user_info->phone
  %li
    %span #{$user->user_info->height} cm,
    %span #{$user->user_info->weight} kg


@@ guests/id.html.haml
- layout 'default';
- title $user->name . '님';

%div= include 'guests/status',     user => $user
%div= include 'guests/breadcrumb', user => $user, status_id => 1;
%h3 주문내역
%ul
  - for my $order (@$orders) {
    - if ($order->status) {
      %li
        %a{:href => "#{url_for('/orders/' . $order->id)}"}
          - if ($order->status->name eq '대여중') {
            - if (calc_overdue($order->target_date, DateTime->now())) {
              %span.label.label-important 연체중
            - } else {
              %span.label.label-important= $order->status->name
            - }
            %span.highlight{:title => '대여일'}= $order->rental_date->ymd
            ~
            %span{:title => '반납예정일'}= $order->target_date->ymd
          - } else {
            %span.label= $order->status->name
            %span.highlight{:title => '대여일'}= $order->rental_date->ymd
            ~
            %span.highlight{:title => '반납일'}= $order->return_date->ymd
          - }
    - }
  - }


@@ guests/breadcrumb.html.haml
%p
  %a{:href => '/guests/#{$user->id}'}= $user->name
  님
  - if ( $user->user_info->visit_date ) {
    %strong= $user->user_info->visit_date->ymd
    %span 방문
  - }
  %div
    %span.label.label-info.search-label
      %a{:href => "#{url_with('/search')->query([q => $user->bust])}///#{$status_id}"}= $user->bust
    %span.label.label-info.search-label
      %a{:href => "#{url_with('/search')->query([q => '/' . $user->waist . '//' . $status_id])}"}= $user->waist
    %span.label.label-info.search-label
      %a{:href => "#{url_with('/search')->query([q => '//' . $user->arm])}/#{$status_id}"}= $user->arm
    %span.label= $user->length
    %span.label= $user->height
    %span.label= $user->weight


@@ guests/breadcrumb/radio.html.haml
%label.radio.inline
  %input{:type => 'radio', :name => 'gid', :value => '#{$user->id}'}
  %a{:href => '/guests/#{$user->id}'}= $user->name
  님
  - if ( $user->user_info->visit_date ) {
    %strong= $user->user_info->visit_date->ymd
    %span 방문
  - }
%div
  %i.icon-envelope
  %a{:href => "mailto:#{$user->email}"}= $user->email
%div.muted= $user->user_info->phone
%div
  %span.label.label-info= $user->user_info->bust
  %span.label.label-info= $user->user_info->waist
  %span.label.label-info= $user->user_info->arm
  %span.label= $user->user_info->leg
  %span.label= $user->user_info->height
  %span.label= $user->user_info->weight


@@ donors/breadcrumb/radio.html.haml
%input{:type => 'radio', :name => 'donor_id', :value => '#{$donor->id}'}
%a{:href => '/donors/#{$donor->id}'}= $donor->user->name
님
%div
  - if ($donor->email) {
    %i.icon-envelope
    %a{:href => "mailto:#{$donor->email}"}= $donor->email
  - }
  - if ($donor->user_info->phone) {
    %div.muted= $donor->phone
  - }


@@ search.html.haml
- my $id   = 'search';
- my $meta = $sidebar->{meta};
- layout 'default',
-   active_id   => $id,
-   breadcrumbs => [
-     { text => $meta->{$id}{text} },
-   ];
- title $meta->{$id}{text};

.row
  .col-xs-12
    %p
      %span.badge.badge-inverse 매우작음
      %span.badge 작음
      %span.badge.badge-success 맞음
      %span.badge.badge-warning 큼
      %span.badge.badge-important 매우큼
    %p.muted
      %span.text-info 상태
      %span{:class => "#{$status_id == 1 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 1))}"} 1: 대여가능
      %span{:class => "#{$status_id == 2 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 2))}"} 2: 대여중
      %span{:class => "#{$status_id == 3 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 3))}"} 3: 대여불가
      %span{:class => "#{$status_id == 4 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 4))}"} 4: 예약
      %span{:class => "#{$status_id == 5 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 5))}"} 5: 세탁
      %span{:class => "#{$status_id == 6 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 6))}"} 6: 수선
      %span{:class => "#{$status_id == 7 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 7))}"} 7: 분실
      %span{:class => "#{$status_id == 8 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 8))}"} 8: 폐기
      %span{:class => "#{$status_id == 9 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 9))}"} 9: 반납
      %span{:class => "#{$status_id == 10 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 10))}"} 10: 부분반납
      %span{:class => "#{$status_id == 11 ? 'highlight' : ''}"}
        %a{:href => "#{url_with->query(q => _q(status => 11))}"} 11: 반납배송중
    %p.muted
      %span.text-info 종류
      - for (qw/ jacket pants shirt shoes hat tie waistcoat coat onepiece skirt blouse /) {
        %span{:class => "#{$category eq $_ ? 'highlight' : ''}"}
          %a{:href => "#{url_with->query(q => _q(category => $_))}"}= $_
      - }

.row
  .col-xs-12
    .search
      %form{ :method => 'get', :action => '' }
        .input-group
          %input#gid{:type => 'hidden', :name => 'gid', :value => "#{$gid}"}
          %input#q.form-control{ :type => 'text', :placeholder => '가슴/허리/팔/상태/종류', :name => 'q', :value => "#{$q}" }
          %span.input-group-btn
            %button#btn-clothes-search.btn.btn-sm.btn-default{ :type => 'submit' }
              %i.icon-search.bigger-110 검색

    .space-10

    .col-xs-12.col-lg-10
      %a.btn.btn-sm.btn-info{:href => "#{url_with->query([color => ''])}"} 모두 보기
      %a.btn.btn-sm.btn-black{:href => "#{url_with->query([color => 'B'])}"} 검정(B)
      %a.btn.btn-sm.btn-navy{:href => "#{url_with->query([color => 'N'])}"} 감청(N)
      %a.btn.btn-sm.btn-gray{:href => "#{url_with->query([color => 'G'])}"} 회색(G)
      %a.btn.btn-sm.btn-red{:href => "#{url_with->query([color => 'R'])}"} 빨강(R)
      %a.btn.btn-sm.btn-whites{:href => "#{url_with->query([color => 'W'])}"} 흰색(W)

.space-10

.row
  .col-xs-12
    - if ($q) {
      %p
        %strong= $q
        %span.muted 의 검색결과
    - }

.row
  .col-xs-12
    = include 'guests/breadcrumb', user => $user if $user

.row
  .col-xs-12
    %ul.ace-thumbnails
      - while (my $c = $clothes_list->next) {
        %li
          %a{:href => '/clothes/#{$c->code}'}
            %img{:src => 'http://placehold.it/160x160', :alt => '#{$c->code}'}

          .tags-top-ltr
            %span.label-holder
              %span.label.label-warning.search-label
                %a{:href => '/clothes/#{$c->code}'}= $c->code

          .tags
            %span.label-holder
              - if ($c->bust) {
                %span.label.label-info.search-label
                  %a{:href => "#{url_with->query([p => 1, q => $c->bust . '///' . $status_id])}"}= $c->bust
                - if ($c->bottom) {
                  %span.label.label-info.search-label
                    %a{:href => "#{url_with->query([p => 1, q => '/' . $c->bottom->waist . '//' . $status_id])}"}= $c->bottom->waist
                - }
              - }
              - if ($c->arm) {
                %span.label.label-info.search-label
                  %a{:href => "#{url_with->query([p => 1, q => '//' . $c->arm . '/' . $status_id])}"}= $c->arm
              - }
              - if ($c->length) {
                %span.label.label-info.search-label= $c->length
              - }

            %span.label-holder
              - if ($c->status->name eq '대여가능') {
                %span.label.label-success= $c->status->name
              - }
              - elsif ($c->status->name eq '대여중') {
                %span.label.label-important= $c->status->name
                - if (my $order = $c->orders({ status_id => 2 })->next) {
                  %small.muted{:title => '반납예정일'}= $order->target_date->ymd if $order->target_date
                - }
              - }
              - else {
                %span.label= $c->status->name
              - }
          .satisfaction
            %ul
              - for my $s ($c->satisfactions({}, { rows => 5, order_by => { -desc => [qw/create_date/] } })) {
                %li
                  %span.badge{:class => 'satisfaction-#{$s->bust || 0}'}= $s->guest->bust
                  %span.badge{:class => 'satisfaction-#{$s->waist || 0}'}= $s->guest->waist
                  %span.badge{:class => 'satisfaction-#{$s->arm || 0}'}=   $s->guest->arm
                  %span.badge{:class => 'satisfaction-#{$s->top_fit || 0}'}    상
                  %span.badge{:class => 'satisfaction-#{$s->bottom_fit || 0}'} 하
                  - if ($user && $s->user_id == $user->id) {
                    %i.icon-star{:title => '대여한적 있음'}
                  - }
              - }
      - } # end of while

.row
  .col-xs-12
    .center
      = include 'pagination'


@@ clothes/code.html.haml
- layout 'default', jses => ['clothes-code.js'];
- title 'clothes/' . $clothes->code;

%h1
  %a{:href => ''}= $clothes->code
  %span - #{$clothes->category}

%form#edit
  %a#btn-edit.btn.btn-sm{:href => '#'} edit
  #input-edit{:style => 'display: none'}
    - use v5.14;
    - no warnings 'experimental';
    - given ( $clothes->category ) {
      - when ( /^(jacket|shirt|waistcoat|coat|blouse)$/i ) {
        %input{:type => 'text', :name => 'bust', :value => '#{$clothes->bust}', :placeholder => '가슴둘레'}
        %input{:type => 'text', :name => 'arm',  :value => '#{$clothes->arm}',  :placeholder => '팔길이'}
      - }
      - when ( /^(pants|skirt)$/i ) {
        %input{:type => 'text', :name => 'waist',  :value => '#{$clothes->waist}',  :placeholder => '허리둘레'}
        %input{:type => 'text', :name => 'length', :value => '#{$clothes->length}', :placeholder => '기장'}
      - }
      - when ( /^(shoes)$/i ) {
        %input{:type => 'text', :name => 'length', :value => '#{$clothes->length}', :placeholder => '발크기'}
      - }
    - }
    %input#btn-submit.btn.btn-sm{:type => 'submit', :value => 'Save Changes'}
    %a#btn-cancel.btn.btn-sm{:href => '#'} Cancel

%h4= $clothes->compatible_code

.row
  .span8
    - if ($clothes->status->name eq '대여가능') {
      %span.label.label-success= $clothes->status->name
    - } elsif ($clothes->status->name eq '대여중') {
      %span.label.label-important= $clothes->status->name
      - if (my $order = $clothes->orders({ status_id => 2 })->next) {
        - if ($order->target_date) {
          %small.highlight{:title => '반납예정일'}
            %a{:href => "/orders/#{$order->id}"}= $order->target_date->ymd
        - }
      - }
    - } else {
      %span.label= $clothes->status->name
    - }

    %span
      - if ($clothes->top) {
        %a{:href => '/clothes/#{$clothes->top->code}'}= $clothes->top->code
      - }
      - if ($clothes->bottom) {
        %a{:href => '/clothes/#{$clothes->bottom->code}'}= $clothes->bottom->code
      - }

    %div
      %img.img-polaroid{:src => 'http://placehold.it/200x200', :alt => '#{$clothes->code}'}

    %div
      - if ($clothes->bust) {
        %span.label.label-info.search-label
          %a{:href => "#{url_with('/search')->query([q => $clothes->bust])}///1"}= $clothes->bust
      - }
      - if ($clothes->waist) {
        %span.label.label-info.search-label
          %a{:href => "#{url_with('/search')->query([q => '/' . $clothes->waist . '//1'])}"}= $clothes->waist
      - }
      - if ($clothes->arm) {
        %span.label.label-info.search-label
          %a{:href => "#{url_with('/search')->query([q => '//' . $clothes->arm])}/1"}= $clothes->arm
      - }
      - if ($clothes->length) {
        %span.label.label-info.search-label= $clothes->length
      - }
    - if ($clothes->donor) {
      %h3= $clothes->donor->name
      %p.muted 님께서 기증하셨습니다
    - }
  .span4
    %ul
      - for my $order ($clothes->orders({ status_id => { '!=' => undef } }, { order_by => { -desc => [qw/rental_date/] } })) {
        %li
          %a{:href => '/guests/#{$order->guest->id}'}= $order->guest->user->name
          님
          - if ($order->status && $order->status->name eq '대여중') {
            - if (calc_overdue($order->target_date, DateTime->now())) {
              %span.label.label-important 연체중
            - } else {
              %span.label.label-important= $order->status->name
            - }
          - } else {
            %span.label= $order->status->name
          - }
          %a.highlight{:href => '/orders/#{$order->id}'}
            %time{:title => '대여일'}= $order->rental_date->ymd
      - }


@@ pagination.html.ep
<ul class="pagination">
  <li class="previous">
    <a href="<%= url_with->query([p => $pageset->first_page]) %>">
      <i class="icon-double-angle-left"></i>
      <i class="icon-double-angle-left"></i>
    </a>
  </li>

  % if ( $pageset->previous_set ) {
  <li class="previous">
    <a href="<%= url_with->query([p => $pageset->previous_set]) %>">
      <i class="icon-double-angle-left"></i>
    </a>
  </li>
  % }
  % else {
  <li class="previous disabled">
    <a href="#">
      <i class="icon-double-angle-left"></i>
    </a>
  </li>
  % }

  % for my $p ( @{$pageset->pages_in_set} ) {
  %   if ( $p == $pageset->current_page ) {
  <li class="active"> <a href="#"> <%= $p %> </a> </li>
  %   }
  %   else {
  <li> <a href="<%= url_with->query([p => $p]) %>"> <%= $p %> </a> </li>
  %   }
  % }

  % if ( $pageset->next_set ) {
  <li class="previous">
    <a href="<%= url_with->query([p => $pageset->next_set]) %>">
      <i class="icon-double-angle-right"></i>
    </a>
  </li>
  % }
  % else {
  <li class="previous disabled">
    <a href="#">
      <i class="icon-double-angle-right"></i>
    </a>
  </li>
  % }

  <li class="next">
    <a href="<%= url_with->query([p => $pageset->last_page]) %>">
      <i class="icon-double-angle-right"></i>
      <i class="icon-double-angle-right"></i>
    </a>
  </li>
</ul>


@@ bad_request.html.haml
- layout 'default';
- title 'Bad request';

%h1 400 Bad request
- if ($error) {
  %p.text-error= $error
- }


@@ rental.html.haml
- my $id   = 'rental';
- my $meta = $sidebar->{meta};
- layout 'default',
-   active_id   => $id,
-   breadcrumbs => [
-     { text => $meta->{$id}{text} },
-   ];
- title $meta->{$id}{text};

.pull-right
  %form.form-search{:method => 'get', :action => ''}
    %input.input-medium.search-query{:type => 'text', :id => 'search-query', :name => 'q', :placeholder => '이메일, 이름 또는 휴대폰번호'}
    %button.btn{:type => 'submit'} 검색

.search
  %form#clothes-search-form
    .input-group
      %input#clothes-id.form-control{ :type => 'text', :placeholder => '품번' }
      %span.input-group-btn
        %button#btn-clothes-search.btn.btn-sm.btn-default{ :type => 'button' }
          %i.icon-search.bigger-110 검색
      %span.input-group-btn
        %button#btn-clear.btn.btn.btn-sm.btn-default{:type => 'button'}
          %i.icon-eraser.bigger-110 지우기

.space-8

#clothes-table
  %form#order-form{:method => 'post', :action => '/orders'}
    %table.table.table-striped.table-bordered.table-hover
      %thead
        %tr
          %th.center
            %label
              %input#input-check-all.ace{ :type => 'checkbox' }
              %span.lbl
          %th 옷
          %th 상태
          %th 기타
      %tbody
    %ul
    #action-buttons{:style => 'display: none'}
      %span 선택한 항목을
      %button.btn.btn-mini{:type => 'button', :data-status => '대여'} 대여
      %span 합니다.
    .span4
      %ul
        - for my $u (@$users) {
          %li= include 'guests/breadcrumb/radio', user => $u
        - }

:plain
  <script id="tpl-row-checkbox-disabled" type="text/html">
    <tr data-clothes-id="<%= id %>" data-order-id="<%= order_id %>">
      <td class="center">
        <label>
          <input class="ace" type="checkbox" disabled>
          <span class="lbl"></span>
        </label>
      </td>
      <td> <a href="/clothes/<%= code %>"> <%= code %> </a> </td> <!-- 옷 -->
      <td>
        <span class="order-status label">
          <%= status %>
          <span class="late-fee"><%= late_fee ? late_fee + '원' : '' %></span>
        </span>
      </td> <!-- 상태 -->
      <td>
        <span><%= category %></span>
        <span><%= price %>원</span>
        <a href="/orders/<%= order_id %>"><span class="label label-info arrowed-right arrowed-in">
          <strong>주문서</strong>
          <time class="js-relative-date" datetime="<%= rental_date.raw %>" title="<%= rental_date.ymd %>"><%= rental_date.md %></time>
          ~
          <time class="js-relative-date" datetime="<%= target_date.raw %>" title="<%= target_date.ymd %>"><%= target_date.md %></time>
        </span></a>
      </td> <!-- 기타 -->
    </tr>
  </script>

:plain
  <script id="tpl-row-checkbox-enabled" type="text/html">
    <tr class="row-checkbox" data-clothes-id="<%= id %>">
      <td class="center">
        <label>
          <input class="ace" type="checkbox" name="clothes-id" value="<%= id %>" data-clothes-id="<%= id %>" checked="checked">
          <span class="lbl"></span>
        </label>
      </td>
      <td> <a href="/clothes/<%= code %>"> <%= code %> </a> </td> <!-- 옷 -->
      <td> <span class="order-status label"><%= status %></span> </td> <!-- 상태 -->
      <td>
        <span><%= category %></span>
        <span><%= price %>원</span>
      </td> <!-- 기타 -->
    </tr>
  </script>


@@ orders.html.haml
- my $id   = 'orders';
- my $meta = $sidebar->{meta};
- layout 'default',
-   active_id   => $id,
-   breadcrumbs => [
-     { text => $meta->{'menu-orders'}{text} },
-     { text => $meta->{$id}{text} },
-   ];
- title $meta->{$id}{text};

#order-table
  %table.table.table-striped.table-bordered.table-hover
    %thead
      %tr
        %th #
        %th 상태
        %th 기간
        %th 대여자
        %th 담당자
        %th 기타
    %tbody
      - while ( my $order = $orders->next ) {
        - next unless $order->status;
        %tr
          %td
            %a{ :href => "#{url_for('/orders/' . $order->id)}" }= $order->id
          %td
            %a{ :href => "#{url_for('/orders/' . $order->id)}" }
              - use v5.14;
              - no warnings 'experimental';
              - given ( $order->status->name ) {
                - when ('대여가능') {
                  %span.label.label-success.order-status
                    = $order->status->name
                - }
                - when (/세탁|수선|분실|폐기|반납|대여불가|예약/) {
                  %span.label.label-info.order-status
                    = $order->status->name
                - }
                - when (/반납배송중|부분반납/) {
                  %span.label.label-warning.order-status
                    = $order->status->name
                - }
                - when (/대여중/) {
                  - my $late_fee = calc_late_fee($order);
                  - if ($late_fee) {
                    %span.label.label-important.order-status
                      = $order->status->name . '(연체)'
                      %span.late-fee= "${late_fee}원"
                  - }
                  - else {
                    %span.label.label-warning.order-status
                      = $order->status->name
                  - }
                - }
                - default {
                  %span.label.order-status
                    = $order->status->name
                - }
              - }
          %td
            = $order->rental_date->ymd . q{ ~ } . $order->target_date->ymd
          %td= $order->guest->user->name
          %td= $order->staff_name
          %td
            - for my $c ( $order->cloths ) {
              %span
                %a{ :href => '/clothes/#{$c->code}' }= $c->category
            - }
      - }


@@ orders/id/nil_status.html.haml
- layout 'default', jses => ['orders-id.js'];
- title '주문확인';

%div.pull-right= include 'guests/breadcrumb', guest => $order->guest, status_id => ''

%div
  %p.muted
    최종금액 = 정상가 + 추가금액 - 에누리금액
  %p#total_price
    %strong#total_fee{:title => '최종금액'}
    %span =
    %span#origin_fee{:title => '정상가'}
    %span +
    %span#additional_fee{:title => '추가금액'}
    %span -
    %span#discount_fee{:title => '에누리금액'}

%form.form-horizontal{:method => 'post', :action => ''}
  %legend
    - my $loop = 0;
    - for my $clothes (@$clothes_list) {
      - $loop++;
      - if ($loop == 1) {
        %span
          %a{:href => '/clothes/#{$clothes->code}'}= $clothes->category
          %small.highlight= commify($clothes->price)
      - } elsif ($loop == 2) {
        %span
          with
          %a{:href => '/clothes/#{$clothes->code}'}= $clothes->category
          %small.highlight= commify($clothes->price)
      - } else {
        %span
          ,
          %a{:href => '/clothes/#{$clothes->code}'}= $clothes->category
          %small.highlight= commify($clothes->price)
      - }
    - }
  .control-group
    %label.control-label{:for => 'input-price'} 가격
    .controls
      %input{:type => 'text', :id => 'input-price', :name => 'price', :value => '#{$price}'}
      원
  .control-group
    %label.control-label{:for => 'input-discount'} 에누리
    .controls
      %input{:type => 'text', :id => 'input-discount', :name => 'discount'}
      원
  .control-group
    %label.control-label 결제방법
    .controls
      %label.radio.inline
        %input{:type => 'radio', :name => 'payment_method', :value => '현금'}
          현금
      %label.radio.inline
        %input{:type => 'radio', :name => 'payment_method', :value => '카드'}
          카드
      %label.radio.inline
        %input{:type => 'radio', :name => 'payment_method', :value => '현금+카드'}
          현금 + 카드
  .control-group
    %label.control-label{:for => 'input-target-date'} 반납예정일
    .controls
      %input#input-target-date{:type => 'text', :name => 'target_date'}
  .control-group
    %label.control-label{:for => 'input-staff'} staff
    .controls
      %input#input-staff{:type => 'text', :name => 'staff_name'}
      %p
        %span.label.clickable 한만일
        %span.label.clickable 김소령
        %span.label.clickable 서동건
        %span.label.clickable 정선경
        %span.label.clickable 김기리
  .control-group
    %label.control-label{:for => 'input-comment'} Comment
    .controls
      %textarea{:id => 'input-comment', :name => 'comment'}
  .control-group
    %label.control-label 만족도
    .controls
      %input.span1{:type => 'text', :name => 'bust',       :placeholder => '가슴'}
      %input.span1{:type => 'text', :name => 'waist',      :placeholder => '허리'}
      %input.span1{:type => 'text', :name => 'arm',        :placeholder => '팔'}
      %input.span1{:type => 'text', :name => 'top_fit',    :placeholder => '상의'}
      %input.span1{:type => 'text', :name => 'bottom_fit', :placeholder => '하의'}
  .control-group
    .controls
      %input.btn.btn-success{:type => 'submit', :value => '대여완료'}

@@ partial/status_label.html.haml
- if ($overdue && $order->status_id == $Opencloset::Constant::STATUS_RENT) {
  %span.label{:class => 'status-#{$order->status_id}'} 연체중
- } else {
  %span.label{:class => 'status-#{$order->status_id}'}= $order->status->name
- }
%p
  %span.highlight= $order->purpose
  으로 방문

@@ partial/order_info.html.haml
- if ($order->rental_date) {
  %h3
    %time.highlight= $order->rental_date->ymd . ' ~ '
    %time.highlight= $order->return_date->ymd if $order->return_date
  %p.muted= '반납예정일: ' . $order->target_date->ymd if $order->target_date
- }

%h3
  %span.highlight= commify($order->price - $order->discount)
%p.muted= commify($order->discount) . '원 할인'

%p= $order->payment_method
%p= $order->staff_name

- if ($overdue) {
  %p.muted
    %span 연체료
    %strong.text-error= commify($late_fee)
    는 연체일(#{ $overdue }) x 대여금액(#{ commify($order->price) })의 20% 로 계산됩니다
- }

- if ($order->comment) {
  %p.well= $order->comment 
- }


@@ partial/satisfaction.html.haml
%h5 만족도
- my ($c, $w, $a, $t, $b) = ($s->bust || 0, $s->waist || 0, $s->arm || 0, $s->top_fit || 0, $s->bottom_fit || 0);
%p
  %span.badge{:class => "satisfaction-#{$c}"} 가슴
  %span.badge{:class => "satisfaction-#{$w}"} 허리
  %span.badge{:class => "satisfaction-#{$a}"} 팔길이
  %span.badge{:class => "satisfaction-#{$t}"} 상의fit
  %span.badge{:class => "satisfaction-#{$b}"} 하의fit


@@ orders/id/status_rent.html.haml
- my $id   = 'orders-id';
- my $meta = $sidebar->{meta};
- layout 'default',
-   active_id   => $id,
-   breadcrumbs => [
-     { text => $meta->{'orders'}{text}, link => '/orders' },
-     { text => $meta->{$id}{text} },
-   ],
-   ;
- title $meta->{$id}{text} . ': 대여중';

%p= include 'partial/status_label'
%div.pull-right= include 'guests/breadcrumb', guest => $order->guest, status_id => ''
%p.text-info 반납품목을 확인해주세요
#clothes-category
  %form#form-clothes-code
    %fieldset
      .input-append
        %input#input-clothes-code.input-large{:type => 'text', :placeholder => '품번'}
        %button#btn-clothes-code.btn{:type => 'button'} 입력
      - for my $clothes (@$clothes_list) {
        %label.checkbox
          %input.input-clothes{:type => 'checkbox', :data-clothes-code => '#{$clothes->code}'}
          %a{:href => '/clothes/#{$clothes->code}'}= $clothes->category
          %small.highlight= commify($clothes->price)
      - }
%div= include 'partial/order_info'

%form#form-return.form-horizontal{:method => 'post', :action => "#{url_for('')}"}
  %fieldset
    %legend 연체료 및 반납방법
    .control-group
      %label 연체료
      .controls
        %input#input-late_fee.input-mini{:type => 'text', :name => 'late_fee', :placeholder => '연체료'}
    .control-group
      %label{:for => '#input-ldiscount'} 연체료의 에누리
      .controls
        %input#input-ldiscount.input-mini{:type => 'text', :name => 'l_discount', :placeholder => '연체료의 에누리'}
    .control-group
      %label 반납방법
      .controls
        %label.radio.inline
          %input{:type => 'radio', :name => 'return_method', :value => '방문'}
          방문
        %label.radio.inline
          %input{:type => 'radio', :name => 'return_method', :value => '택배'}
          택배
    .control-group
      %label 결제방법
      .controls
        %label.radio.inline
          %input{:type => 'radio', :name => 'l_payment_method', :value => '현금'}
          현금
        %label.radio.inline
          %input{:type => 'radio', :name => 'l_payment_method', :value => '카드'}
          카드
        %label.radio.inline
          %input{:type => 'radio', :name => 'l_payment_method', :value => '현금+카드'}
          현금+카드
    .control-group
      .controls
        %button.btn.btn-success{:type => 'submit'} 반납
        %a.pull-right#btn-order-cancel.btn.btn-danger{:href => '#{url_for()}'} 주문취소

%p= include 'partial/satisfaction', s => $satisfaction


@@ orders/id/status_return.html.haml
- layout 'default', jses => ['orders-id.js'];
- title '주문확인 - 반납';

%p= include 'partial/status_label'
%div.pull-right= include 'guests/breadcrumb', guest => $order->guest, status_id => ''

- for my $clothes (@$clothes_list) {
  %p
    %a{:href => '/clothes/#{$clothes->code}'}= $clothes->category
    %small.highlight= commify($clothes->price)
- }

%div= include 'partial/order_info'
%p= commify($order->late_fee)
%p= $order->return_method
%p= '연체료 ' . commify($order->l_discount) . ' 원 할인'
%p= include 'partial/satisfaction', s => $satisfaction


@@ orders/id/status_partial_return.html.haml
- layout 'default', jses => ['orders-id.js'];
- title '주문확인 - 부분반납';

%p= include 'partial/status_label'
%div.pull-right= include 'guests/breadcrumb', guest => $order->guest, status_id => ''
#clothes-category
  %form#form-clothes-code
    %fieldset
      .input-append
        %input#input-clothes-code.input-large{:type => 'text', :placeholder => '품번'}
        %button#btn-clothes-code.btn{:type => 'button'} 입력
      - for my $clothes (@$clothes_list) {
        %label.checkbox
          - if ($clothes->status_id != $Opencloset::Constant::STATUS_PARTIAL_RETURN) {
            %input.input-clothes{:type => 'checkbox', :checked => 'checked', :data-clothes-code => '#{$clothes->code}'}
          - } else {
            %input.input-clothes{:type => 'checkbox', :data-clothes-code => '#{$clothes->code}'}
          - }
          %a{:href => '/clothes/#{$clothes->code}'}= $clothes->category
          %small.highlight= commify($clothes->price)
      - }
%div= include 'partial/order_info'
%p= commify($order->late_fee)
%p= $order->return_method
%form#form-return.form-horizontal{:method => 'post', :action => "#{url_for('')}"}
  %fieldset
    .control-group
      .controls
        %button.btn.btn-success{:type => 'submit'} 반납
%p= include 'partial/satisfaction', s => $satisfaction


@@ new-clothes.html.haml
- my $id   = 'new-clothes';
- my $meta = $sidebar->{meta};
- layout 'default',
-   active_id   => $id,
-   breadcrumbs => [
-     { text => $meta->{$id}{text} },
-   ],
-   jses => [
-     '/lib/bootstrap/js/fuelux/fuelux.wizard.min.js',
-   ];
- title $meta->{$id}{text};

#new-clothes
  .row-fluid
    .span12
      .widget-box
        .widget-header.widget-header-blue.widget-header-flat
          %h4.lighter 새 옷 등록

        .widget-body
          .widget-main
            /
            / step navigation
            /
            #fuelux-wizard.row-fluid{ "data-target" => '#step-container' }
              %ul.wizard-steps
                %li.active{ "data-target" => "#step1" }
                  %span.step  1
                  %span.title 기증자 검색
                %li{ "data-target" => "#step2" }
                  %span.step  2
                  %span.title 기증자 정보
                %li{ "data-target" => "#step3" }
                  %span.step  3
                  %span.title 새 옷 등록
                %li{ "data-target" => "#step4" }
                  %span.step  4
                  %span.title 등록 완료

            %hr

            #step-container.step-content.row-fluid.position-relative
              /
              / step1
              /
              #step1.step-pane.active
                %h3.lighter.block.green 새 옷을 기증해주신 분이 누구신가요?
                .form-horizontal
                  /
                  / 기증자 검색
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3 기증자 검색:
                    .col-xs-12.col-sm-9
                      .search
                        .input-group
                          %input#donor-search.form-control{ :name => 'donor-search' :type => 'text', :placeholder => '이름 또는 이메일, 휴대전화 번호' }
                          %span.input-group-btn
                            %button#btn-donor-search.btn.btn-default.btn-sm{ :type => 'submit' }
                              %i.icon-search.bigger-110 검색
                  /
                  / 기증자 선택
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => "email" } 기증자 선택:
                    .col-xs-12.col-sm-9
                      #donor-search-list
                        %div
                          %label.blue
                            %input.ace.valid{ :name => 'user-id', :type => 'radio', :value => '0' }
                            %span.lbl= ' 기증자를 모릅니다.'
                      :plain
                        <script id="tpl-new-clothes-donor-id" type="text/html">
                          <div>
                            <label class="blue highlight">
                              <input type="radio" class="ace valid" name="user-id" value="<%= user_id %>" data-donor-id="<%= id %>" data-user-id="<%= user_id %>">
                              <span class="lbl"> <%= name %> (<%= email %>)</span>
                              <span><%= address %></span>
                            </label>
                          </div>
                        </script>
              /
              / step2
              /
              #step2.step-pane
                %h3.lighter.block.green 기증자의 정보를 입력하세요.
                %form#donor-info.form-horizontal{ :method => 'get', :novalidate="novalidate" }
                  /
                  / 이름
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'donor-name' } 이름:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#donor-name.valid.col-xs-12.col-sm-6{ :name => 'name', :type => 'text' }

                  .space-2

                  /
                  / 전자우편
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'donor-email' } 전자우편:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#donor-email.valid.col-xs-12.col-sm-6{ :name => 'email', :type => 'text' }

                  .space-2

                  /
                  / 나이
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'donor-age' } 나이:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#donor-age.valid.col-xs-12.col-sm-3{ :name => 'age', :type => 'text' }

                  .space-2

                  /
                  / 성별
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'donor-gender' } 성별:
                    .col-xs-12.col-sm-9
                      %div
                        %label.blue
                          %input.ace.valid{ :name => 'gender', :type => 'radio', :value => '1' }
                          %span.lbl= ' 남자'
                      %div
                        %label.blue
                          %input.ace.valid{ :name => 'gender', :type => 'radio', :value => '2' }
                          %span.lbl= ' 여자'

                  .space-2

                  /
                  / 휴대전화
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'donor-phone' } 휴대전화:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#donor-phone.valid.col-xs-12.col-sm-6{ :name => 'phone', :type => 'text' }

                  .space-2

                  /
                  / 주소
                  /
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'donor-address' } 주소:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %input#donor-address.valid.col-xs-12.col-sm-8{ :name => 'address', :type => 'text' }
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'donation-msg' } 전하실 말:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %textarea#donation-msg.valid.col-xs-12.col-sm-6{ :name => 'donation_msg' }
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'comment' } 기타:
                    .col-xs-12.col-sm-9
                      .clearfix
                        %textarea#comment.valid.col-xs-12.col-sm-6{ :name => 'comment' }

              /
              / step3
              /
              #step3.step-pane
                %h3.lighter.block.green 새로운 옷의 종류와 치수를 입력하세요.

                .form-horizontal
                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'clothes-type' } 종류:
                    .col-xs-12.col-sm-6
                      %select#clothes-type{ :name => 'clothes-type', 'data-placeholder' => '옷의 종류를 선택하세요', :size => '14' }
                        %option{ :value => "#{0x0001 | 0x0002}" } Jacket & Pants
                        %option{ :value => "#{0x0001 | 0x0020}" } Jacket & Skirts
                        %option{ :value => "#{0x0001}"          } Jacket
                        %option{ :value => "#{0x0002}"          } Pants
                        %option{ :value => "#{0x0004}"          } Shirts
                        %option{ :value => "#{0x0008}"          } Shoes
                        %option{ :value => "#{0x0010}"          } Hat
                        %option{ :value => "#{0x0020}"          } Tie
                        %option{ :value => "#{0x0040}"          } Waistcoat
                        %option{ :value => "#{0x0080}"          } Coat
                        %option{ :value => "#{0x0100}"          } Onepiece
                        %option{ :value => "#{0x0200}"          } Skirt
                        %option{ :value => "#{0x0400}"          } Blouse

                  .space-2

                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3 성별:
                    .col-xs-12.col-sm-9
                      %div
                        %label.blue
                          %input.ace.valid{ :name => 'clothes-gender', :type => 'radio', :value => '1' }
                          %span.lbl= ' 남성용'
                      %div
                        %label.blue
                          %input.ace.valid{ :name => 'clothes-gender', :type => 'radio', :value => '2' }
                          %span.lbl= ' 여성용'
                      %div
                        %label.blue
                          %input.ace.valid{ :name => 'clothes-gender', :type => 'radio', :value => '3' }
                          %span.lbl= ' 남여공용'

                  #display-clothes-color
                    .space-2

                    .form-group.has-info
                      %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'clothes-color' } 색상:
                      .col-xs-12.col-sm-4
                        %select#clothes-color{ :name => 'color', 'data-placeholder' => '옷의 색상을 선택하세요', :size => '6' }
                          %option{ :value => 'B' } 검정(B)
                          %option{ :value => 'N' } 감청(N)
                          %option{ :value => 'G' } 회색(G)
                          %option{ :value => 'R' } 빨강(R)
                          %option{ :value => 'W' } 흰색(W)

                  #display-clothes-bust
                    .space-2

                    .form-group.has-info
                      %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'clothes-bust' } 가슴:
                      .col-xs-12.col-sm-5
                        .input-group
                          %input#clothes-bust.valid.form-control{ :name => 'bust', :type => 'text' }
                          %span.input-group-addon
                            %i cm

                  #display-clothes-arm
                    .space-2

                    .form-group.has-info
                      %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'clothes-arm' } 팔 길이:
                      .col-xs-12.col-sm-5
                        .input-group
                          %input#clothes-arm.valid.form-control{ :name => 'arm', :type => 'text' }
                          %span.input-group-addon
                            %i cm

                  #display-clothes-waist
                    .space-2

                    .form-group.has-info
                      %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'clothes-waist' } 허리:
                      .col-xs-12.col-sm-5
                        .input-group
                          %input#clothes-waist.valid.form-control{ :name => 'waist', :type => 'text' }
                          %span.input-group-addon
                            %i cm

                  #display-clothes-hip
                    .space-2

                    .form-group.has-info
                      %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'clothes-hip' } 엉덩이:
                      .col-xs-12.col-sm-5
                        .input-group
                          %input#clothes-hip.valid.form-control{ :name => 'hip', :type => 'text' }
                          %span.input-group-addon
                            %i cm

                  #display-clothes-length
                    .space-2

                    .form-group.has-info
                      %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'clothes-length' } 기장:
                      .col-xs-12.col-sm-5
                        .input-group
                          %input#clothes-length.valid.form-control{ :name => 'length', :type => 'text' }
                          %span.input-group-addon
                            %i cm

                  #display-clothes-foot
                    .space-2

                    .form-group.has-info
                      %label.control-label.no-padding-right.col-xs-12.col-sm-3{ :for => 'clothes-foot' } 발 크기:
                      .col-xs-12.col-sm-5
                        .input-group
                          %input#clothes-foot.valid.form-control{ :name => 'foot', :type => 'text' }
                          %span.input-group-addon
                            %i mm

                  .form-group.has-info
                    %label.control-label.no-padding-right.col-xs-12.col-sm-3= ' '
                    .col-xs-12.col-sm-5
                      .input-group
                        %button#btn-clothes-reset.btn.btn-default 지움
                        %button#btn-clothes-add.btn.btn-primary 추가

                  .hr.hr-dotted

                  %form.form-horizontal{ :method => 'get', :novalidate => 'novalidate' }
                    .form-group.has-info
                      %label.control-label.no-padding-right.col-xs-12.col-sm-3
                        추가할 의류 선택:
                        %br
                        %a#btn-clothes-select-all.btn.btn-xs.btn-success{ :role => 'button' } 모두 선택
                      .col-xs-12.col-sm-9
                        #display-clothes-list
                        :plain
                          <script id="tpl-new-clothes-clothes-item" type="text/html">
                            <div>
                              <label>
                                <input type="checkbox" class="ace valid" name="clothes-list"
                                  value="<%= [ donor_id, cloth_type, cloth_color, cloth_bust, cloth_waist, cloth_hip, cloth_arm, cloth_length, cloth_foot, cloth_gender ].join('-') %>"
                                  data-donor-id="<%= donor_id %>"
                                  data-clothes-type="<%= cloth_type %>"
                                  data-clothes-color="<%= cloth_color %>"
                                  data-clothes-bust="<%= cloth_bust %>"
                                  data-clothes-arm="<%= cloth_arm %>"
                                  data-clothes-waist="<%= cloth_waist %>"
                                  data-clothes-hip="<%= cloth_hip %>"
                                  data-clothes-length="<%= cloth_length %>"
                                  data-clothes-foot="<%= cloth_foot %>"
                                  data-clothes-gender="<%= cloth_gender %>"
                                />
                                <%
                                  var cloth_detail = []
                                  typeof yourvar != 'undefined'
                                  if ( cloth_gender       >  0          ) { cloth_detail.push( cloth_gender_str                     ) }
                                  if ( typeof cloth_color != 'undefined') { cloth_detail.push( "색상("    + cloth_color_str + ")"   ) }
                                  if ( cloth_bust         >  0          ) { cloth_detail.push( "가슴("    + cloth_bust      + "cm)" ) }
                                  if ( cloth_arm          >  0          ) { cloth_detail.push( "팔 길이(" + cloth_arm       + "cm)" ) }
                                  if ( cloth_waist        >  0          ) { cloth_detail.push( "허리("    + cloth_waist     + "cm)" ) }
                                  if ( cloth_hip          >  0          ) { cloth_detail.push( "엉덩이("  + cloth_hip       + "cm)" ) }
                                  if ( cloth_length       >  0          ) { cloth_detail.push( "기장("    + cloth_length    + "cm)" ) }
                                  if ( cloth_foot         >  0          ) { cloth_detail.push( "발 크기(" + cloth_foot      + "mm)" ) }
                                %>
                                <span class="lbl"> &nbsp; <%= cloth_type_str %>: <%= cloth_detail.join(', ') %> </span>
                              </label>
                            </div>
                            <div class="space-4"></div>
                          </script>

              /
              / step4
              /
              #step4.step-pane
                %h3.lighter.block.green 등록이 완료되었습니다!

            %hr

            .wizard-actions.row-fluid
              %button.btn.btn-prev{ :disabled => "disabled" }
                %i.icon-arrow-left
                이전
              %button.btn.btn-next.btn-success{ "data-last" => "완료 " }
                다음
                %i.icon-arrow-right.icon-on-right


@@ layouts/default.html.haml
!!! 5
%html{:lang => "ko"}
  %head
    %title= title . ' - ' . $site->{name}
    = include 'layouts/default/meta'
    = include 'layouts/default/before-css'
    = include 'layouts/default/before-js'
    = include 'layouts/default/theme'
    = include 'layouts/default/css-page'
    = include 'layouts/default/after-css'
    = include 'layouts/default/after-js'

  %body
    = include 'layouts/default/navbar'
    #main-container.main-container
      .main-container-inner
        %a#menu-toggler.menu-toggler{:href => '#'}
          %span.menu-text
        = include 'layouts/default/sidebar'
        .main-content
          = include 'layouts/default/breadcrumbs'
          .page-content
            .page-header
              %h1
                = $sidebar->{meta}{$active_id}{text} // q{}
                %small
                  %i.icon-double-angle-right
                  = $sidebar->{meta}{$active_id}{desc} // q{}
            .row
              .col-xs-12
                / PAGE CONTENT BEGINS
                = content
                / PAGE CONTENT ENDS
    = include 'layouts/default/body-js'
    = include 'layouts/default/body-js-theme'
    = include 'layouts/default/body-js-page'


@@ layouts/default/meta.html.haml
/ META
    %meta{:charset => "utf-8"}
    %meta{:content => "width=device-width, initial-scale=1.0", :name => "viewport"}


@@ layouts/default/before-css.html.haml
/ CSS
    %link{:rel => "stylesheet", :href => "/lib/bootstrap/css/bootstrap.min.css"}
    %link{:rel => "stylesheet", :href => "/lib/font-awesome/css/font-awesome.min.css"}
    /[if IE 7]
      %link{:rel => "stylesheet", :href => "/lib/font-awesome/css/font-awesome-ie7.min.css"}
    %link{:rel => "stylesheet", :href => "/lib/prettify/css/prettify.css"}
    %link{:rel => "stylesheet", :href => "/lib/datepicker/css/datepicker.css"}
    %link{:rel => "stylesheet", :href => "/lib/select2/select2.css"}


@@ layouts/default/after-css.html.haml
/ CSS
    %link{:rel => "stylesheet", :href => "/css/font-nanum.css"}
    %link{:rel => "stylesheet", :href => "/css/screen.css"}


@@ layouts/default/before-js.html.haml
/ JS


@@ layouts/default/after-js.html.haml
/ JS
    /[if lt IE 9]>
      %script{:src => "/lib/html5shiv/html5shiv.min.js"}
      %script{:src => "/lib/respond/respond.min.js"}


@@ layouts/default/css-page.html.ep
<!-- css-page -->
    <!-- page specific -->
    % my @include_csses = @$csses;
    % #push @include_csses, "$active_id.css" if $active_id;
    % for my $css (@include_csses) {
    %   if ( $css =~ m{^/} ) {
          <link rel="stylesheet" href="<%= $css %>" />
    %   }
    %   else {
          <link rel="stylesheet" href="/css/<%= $css %>" />
    %   }
    % }


@@ layouts/default/body-js.html.ep
<!-- body-js -->
    <!-- Le javascript -->
    <!-- Placed at the end of the document so the pages load faster -->

    <!-- jQuery -->
    <!--[if !IE]> -->
      <script type="text/javascript">
        window.jQuery
          || document.write("<script src='/lib/jquery/js/jquery-2.0.3.min.js'>"+"<"+"/script>");
      </script>
    <!-- <![endif]-->

    <!--[if IE]>
      <script type="text/javascript">
        window.jQuery
          || document.write("<script src='/lib/jquery/js/jquery-1.10.2.min.js'>"+"<"+"/script>");
      </script>
    <![endif]-->

    <script type="text/javascript">
      if ("ontouchend" in document)
        document.write("<script src='/lib/jquery/js/jquery.mobile.custom.min.js'>"+"<"+"/script>");
    </script>

    <!-- bootstrap -->
    <script src="/lib/bootstrap/js/bootstrap.min.js"></script>
    <script src="/lib/bootstrap/js/bootstrap-tag.min.js"></script> <!-- tag -->

    <!--[if lte IE 8]>
      <script src="/lib/excanvas/excanvas.min.js"></script>
    <![endif]-->

    <!-- prettify -->
    <script src="/lib/prettify/js/prettify.js"></script>

    <!-- underscore -->
    <script src="/lib/underscore/underscore-min.js"></script>

    <!-- datepicker -->
    <script src="/lib/datepicker/js/bootstrap-datepicker.js"></script>
    <script src="/lib/datepicker/js/locales/bootstrap-datepicker.kr.js"></script>

    <!-- select2 -->
    <script src="/lib/select2/select2.min.js"></script>
    <script src="/lib/select2/select2_locale_ko.js"></script>

    <!-- bundle -->
    <script src="/js/bundle.js"></script>


@@ layouts/default/body-js-page.html.ep
<!-- body-js-page -->
    <!-- page specific -->
    % my @include_jses = @$jses;
    % my $asset = app->static->file("js/$active_id.js");
    % push @include_jses, "$active_id.js" if $active_id && $asset && $asset->is_file;
    % for my $js (@include_jses) {
    %   if ( $js =~ m{^/} ) {
          <script type="text/javascript" src="<%= $js %>"></script>
    %   }
    %   else {
          <script type="text/javascript" src="/js/<%= $js %>"></script>
    %   }
    % }


@@ layouts/default/theme.html.ep
<!-- theme -->
    <link rel="stylesheet" href="/theme/<%= $theme %>/css/<%= $theme %>-fonts.css" />
    <link rel="stylesheet" href="/theme/<%= $theme %>/css/<%= $theme %>.min.css" />
    <link rel="stylesheet" href="/theme/<%= $theme %>/css/<%= $theme %>-rtl.min.css" />
    <link rel="stylesheet" href="/theme/<%= $theme %>/css/<%= $theme %>-skins.min.css" />
    <!--[if lte IE 8]>
      <link rel="stylesheet" href="/theme/<%= $theme %>/css/<%= $theme %>-ie.min.css" />
    <![endif]-->
    <script src="/theme/<%= $theme %>/js/<%= $theme %>-extra.min.js"></script>


@@ layouts/default/body-js-theme.html.ep
<!-- body js theme -->
    <script src="/theme/<%= $theme %>/js/<%= $theme %>-elements.min.js"></script>
    <script src="/theme/<%= $theme %>/js/<%= $theme %>.min.js"></script>


@@ layouts/default/navbar.html.ep
<!-- navbar -->
    <div class="navbar navbar-default" id="navbar">
      <div class="navbar-container" id="navbar-container">
        <div class="navbar-header pull-left">
          <a href="/" class="navbar-brand">
            <small> <i class="<%= $site->{icon} ? "icon-$site->{icon}" : q{} %>"></i> <%= $site->{name} %> </small>
          </a><!-- /.brand -->
        </div><!-- /.navbar-header -->

        <div class="navbar-header pull-right" role="navigation">
          <ul class="nav <%= $theme %>-nav">
            <li class="grey">
              <a data-toggle="dropdown" class="dropdown-toggle" href="#">
                <i class="icon-tasks"></i>
                <span class="badge badge-grey">4</span>
              </a>

              <ul class="pull-right dropdown-navbar dropdown-menu dropdown-caret dropdown-close">
                <li class="dropdown-header">
                  <i class="icon-ok"></i> 4 Tasks to complete
                </li>

                <li>
                  <a href="#">
                    <div class="clearfix">
                      <span class="pull-left">Software Update</span>
                      <span class="pull-right">65%</span>
                    </div>

                    <div class="progress progress-mini ">
                      <div style="width:65%" class="progress-bar "></div>
                    </div>
                  </a>
                </li>

                <li>
                  <a href="#">
                    <div class="clearfix">
                      <span class="pull-left">Hardware Upgrade</span>
                      <span class="pull-right">35%</span>
                    </div>

                    <div class="progress progress-mini ">
                      <div style="width:35%" class="progress-bar progress-bar-danger"></div>
                    </div>
                  </a>
                </li>

                <li>
                  <a href="#">
                    <div class="clearfix">
                      <span class="pull-left">Unit Testing</span>
                      <span class="pull-right">15%</span>
                    </div>

                    <div class="progress progress-mini ">
                      <div style="width:15%" class="progress-bar progress-bar-warning"></div>
                    </div>
                  </a>
                </li>

                <li>
                  <a href="#">
                    <div class="clearfix">
                      <span class="pull-left">Bug Fixes</span>
                      <span class="pull-right">90%</span>
                    </div>

                    <div class="progress progress-mini progress-striped active">
                      <div style="width:90%" class="progress-bar progress-bar-success"></div>
                    </div>
                  </a>
                </li>

                <li>
                  <a href="#">
                    See tasks with details
                    <i class="icon-arrow-right"></i>
                  </a>
                </li>

              </ul>

              </li> <!-- grey -->

              <li class="purple">
                <a data-toggle="dropdown" class="dropdown-toggle" href="#">
                  <i class="icon-bell-alt icon-animated-bell"></i>
                  <span class="badge badge-important">8</span>
                </a>

                <ul class="pull-right dropdown-navbar navbar-pink dropdown-menu dropdown-caret dropdown-close">
                  <li class="dropdown-header">
                    <i class="icon-warning-sign"></i>
                    8 Notifications
                  </li>

                  <li>
                    <a href="#">
                      <div class="clearfix">
                        <span class="pull-left">
                          <i class="btn btn-xs no-hover btn-pink icon-comment"></i>
                          New Comments
                        </span>
                        <span class="pull-right badge badge-info">+12</span>
                      </div>
                    </a>
                  </li>

                  <li>
                    <a href="#">
                      <i class="btn btn-xs btn-primary icon-user"></i>
                      Bob just signed up as an editor ...
                    </a>
                  </li>

                  <li>
                    <a href="#">
                      <div class="clearfix">
                        <span class="pull-left">
                          <i class="btn btn-xs no-hover btn-success icon-shopping-cart"></i>
                          New Orders
                        </span>
                        <span class="pull-right badge badge-success">+8</span>
                      </div>
                    </a>
                  </li>

                  <li>
                    <a href="#">
                      <div class="clearfix">
                        <span class="pull-left">
                          <i class="btn btn-xs no-hover btn-info icon-twitter"></i>
                          Followers
                        </span>
                        <span class="pull-right badge badge-info">+11</span>
                      </div>
                    </a>
                  </li>

                  <li>
                    <a href="#">
                      See all notifications
                      <i class="icon-arrow-right"></i>
                    </a>
                  </li>
                </ul>
                </li> <!-- purple -->

                <li class="green">
                  <a data-toggle="dropdown" class="dropdown-toggle" href="#">
                    <i class="icon-envelope icon-animated-vertical"></i>
                    <span class="badge badge-success">5</span>
                  </a>

                  <ul class="pull-right dropdown-navbar dropdown-menu dropdown-caret dropdown-close">
                    <li class="dropdown-header">
                      <i class="icon-envelope-alt"></i>
                      5 Messages
                    </li>

                    <li>
                      <a href="#">
                        <img src="https://pbs.twimg.com/profile_images/1814758551/keedi_bigger.jpg" class="msg-photo" alt="Alex's Avatar" />
                        <span class="msg-body">
                          <span class="msg-title">
                            <span class="blue">Alex:</span>
                            Ciao sociis natoque penatibus et auctor ...
                          </span>

                          <span class="msg-time">
                            <i class="icon-time"></i>
                            <span>a moment ago</span>
                          </span>
                        </span>
                      </a>
                    </li>

                    <li>
                      <a href="#">
                        <img src="https://pbs.twimg.com/profile_images/576748805/life.jpg" class="msg-photo" alt="Susan's Avatar" />
                        <span class="msg-body">
                          <span class="msg-title">
                            <span class="blue">Susan:</span>
                            Vestibulum id ligula porta felis euismod ...
                          </span>

                          <span class="msg-time">
                            <i class="icon-time"></i>
                            <span>20 minutes ago</span>
                          </span>
                        </span>
                      </a>
                    </li>

                    <li>
                      <a href="#">
                        <img src="https://pbs.twimg.com/profile_images/684939202/__0019_3441_.jpg" class="msg-photo" alt="Bob's Avatar" />
                        <span class="msg-body">
                          <span class="msg-title">
                            <span class="blue">Bob:</span>
                            Nullam quis risus eget urna mollis ornare ...
                          </span>

                          <span class="msg-time">
                            <i class="icon-time"></i>
                            <span>3:15 pm</span>
                          </span>
                        </span>
                      </a>
                    </li>

                    <li>
                      <a href="#">
                        <img src="https://pbs.twimg.com/profile_images/96856366/img_9494_doldolshadow.jpg" class="msg-photo" alt="Bob's Avatar" />
                        <span class="msg-body">
                          <span class="msg-title">
                            <span class="blue">Bob:</span>
                            Nullam quis risus eget urna mollis ornare ...
                          </span>

                          <span class="msg-time">
                            <i class="icon-time"></i>
                            <span>3:15 pm</span>
                          </span>
                        </span>
                      </a>
                    </li>

                    <li>
                      <a href="inbox.html">
                        See all messages
                        <i class="icon-arrow-right"></i>
                      </a>
                    </li>
                  </ul>
                </li> <!-- green -->

                <li class="light-blue">
                  <a data-toggle="dropdown" href="#" class="dropdown-toggle">
                    <img class="nav-user-photo" src="https://pbs.twimg.com/profile_images/1814758551/keedi_bigger.jpg" alt="Keedi's Photo" />
                    <span class="user-info"> <small>Welcome,</small> Keedi </span>
                    <i class="icon-caret-down"></i>
                  </a>

                  <ul class="user-menu pull-right dropdown-menu dropdown-yellow dropdown-caret dropdown-close">
                    <li> <a href="#"> <i class="icon-cog"></i> 설정 </a> </li>
                    <li> <a href="#"> <i class="icon-user"></i> 프로필 </a> </li>
                    <li class="divider"></li>
                    <li> <a href="#"> <i class="icon-off"></i> 로그아웃 </a> </li>
                  </ul>
                </li> <!-- light-blue -->

          </ul><!-- /.<%= $theme %>-nav -->
        </div><!-- /.navbar-header -->
      </div><!-- /.container -->
    </div>


@@ layouts/default/sidebar.html.ep
<!-- SIDEBAR -->
        <div class="sidebar" id="sidebar">
          <div class="sidebar-shortcuts" id="sidebar-shortcuts">
            <div class="sidebar-shortcuts-large" id="sidebar-shortcuts-large">
              <button class="btn btn-success"> <i class="icon-signal"></i> </button>
              <button class="btn btn-info"   > <i class="icon-pencil"></i> </button>
              <button class="btn btn-warning"> <i class="icon-group" ></i> </button>
              <button class="btn btn-danger" > <i class="icon-cogs"  ></i> </button>
            </div>

            <div class="sidebar-shortcuts-mini" id="sidebar-shortcuts-mini">
              <span class="btn btn-success"></span>
              <span class="btn btn-info"   ></span>
              <span class="btn btn-warning"></span>
              <span class="btn btn-danger" ></span>
            </div>
          </div><!-- #sidebar-shortcuts -->

          % my $menu = begin
          %   my ( $m, $items, $active_id, $level ) = @_;
          %   my $space = $level ? q{  } x ( $level * 2 ) : q{};
          %
          <!-- sidebar items -->
          <%= $space %><ul class="<%= $level ? "submenu" : "nav nav-list" %>">
          %
          %   for my $item (@$items) {
          %     my $meta  = $sidebar->{meta}{$item->{id}};
          %     my $icon  = $meta->{icon} ? "icon-$meta->{icon}" : $level ? "icon-double-angle-right" : q{};
          %     my $link  = $meta->{link} // "/$item->{id}";
          %
          %     if ( $item->{id} eq $active_id ) {
          %       if ( $item->{items} ) {
          %
            <%= $space %><li class="active">
              <%= $space %><a href="<%= $link %>" class="dropdown-toggle">
                <%= $space %><i class="<%= $icon %>"></i>
                <%= $space %><span class="menu-text"> <%= $meta->{text} %> </span>
                <%= $space %><b class="arrow icon-angle-down"></b>
              <%= $space %></a>
              %== $m->( $m, $item->{items}, $active_id, $level + 1 );
            <%= $space %></li>
          %
          %       }
          %       else {
          %
            <%= $space %><li class="active">
              <%= $space %><a href="<%= $link %>">
                <%= $space %><i class="<%= $icon %>"></i>
                <%= $space %><span class="menu-text"> <%= $meta->{text} %> </span>
              <%= $space %></a>
            <%= $space %></li>
          %
          %       }
          %     }
          %     else {
          %       if ( $item->{items} ) {
          %
            <%= $space %><li>
              <%= $space %><a href="<%= $link %>" class="dropdown-toggle">
                <%= $space %><i class="<%= $icon %>"></i>
                <%= $space %><span class="menu-text"> <%= $meta->{text} %> </span>
                <%= $space %><b class="arrow icon-angle-down"></b>
              <%= $space %></a>
              %== $m->( $m, $item->{items}, $active_id, $level + 1 );
            <%= $space %></li>
          %
          %       }
          %       else {
          %
            <%= $space %><li>
              <%= $space %><a href="<%= $link %>">
                <%= $space %><i class="<%= $icon %>"></i>
                <%= $space %><span class="menu-text"> <%= $meta->{text} %> </span>
              <%= $space %></a>
            <%= $space %></li>
          %
          %       }
          %     }
          %   }
          %
          <%= $space %></ul> <!-- <%= $level ? "submenu" : "nav-list" %> -->
          %
          % end
          %
          %== $menu->( $menu, $sidebar->{items}, $active_id, 0 );
          %

          <div class="sidebar-collapse" id="sidebar-collapse">
            <i class="icon-double-angle-left" data-icon1="icon-double-angle-left" data-icon2="icon-double-angle-right"></i>
          </div>
        </div> <!-- sidebar -->


@@ layouts/default/breadcrumbs.html.ep
<!-- BREADCRUMBS -->
          <div class="breadcrumbs" id="breadcrumbs">
            <ul class="breadcrumb">
            % if (@$breadcrumbs) {
              <li> <i class="icon-home home-icon"></i> <a href="/"><%= $sidebar->{meta}{home}{text} %></a> </li>
            %   for my $i ( 0 .. $#$breadcrumbs ) {
            %     my $b = $breadcrumbs->[$i];
            %     if ( $i < $#$breadcrumbs ) {
            %       if ( $b->{link} ) {
              <li> <a href="<%= $b->{link} %>"><%= $b->{text} %></a> </li>
            %       }
            %       else {
              <li> <%= $b->{text} %> </li>
            %       }
            %     }
            %     else {
              <li class="active"> <%= $b->{text} %> </li>
            %     }
            %   }
            % }
            % else {
              <li class="active"> <i class="icon-home home-icon"></i> <a href="/"><%= $sidebar->{meta}{home}{text} %></a> </li>
            % }
            </ul><!-- .breadcrumb -->

            <div class="nav-search" id="nav-search">
              <form class="form-search">
                <span class="input-icon">
                  <input type="text" placeholder="검색 ..." class="nav-search-input" id="nav-search-input" autocomplete="off" />
                  <i class="icon-search nav-search-icon"></i>
                </span>
              </form>
            </div><!-- #nav-search -->
          </div> <!-- breadcrumbs -->


@@ not_found.html.ep
% layout 'error',
%   breadcrumbs => [
%     { text => 'Other Pages' },
%     { text => 'Error 404' },
%   ];
% title '404 Error Page';
<!-- 404 NOT FOUND -->
                <div class="error-container">
                  <div class="well">
                    <h1 class="grey lighter smaller">
                      <span class="blue bigger-125">
                        <i class="icon-sitemap"></i>
                        404
                      </span>
                      Page Not Found
                    </h1>

                    <hr />
                    <h3 class="lighter smaller">We looked everywhere but we couldn't find it!</h3>

                    <div>
                      <form class="form-search">
                        <span class="input-icon align-middle">
                          <i class="icon-search"></i>

                          <input type="text" class="search-query" placeholder="Give it a search..." />
                        </span>
                        <button class="btn btn-sm" onclick="return false;">Go!</button>
                      </form>

                      <div class="space"></div>
                      <h4 class="smaller">Try one of the following:</h4>

                      <ul class="list-unstyled spaced inline bigger-110 margin-15">
                        <li>
                          <i class="icon-hand-right blue"></i>
                          Re-check the url for typos
                        </li>

                        <li>
                          <i class="icon-hand-right blue"></i>
                          Read the faq
                        </li>

                        <li>
                          <i class="icon-hand-right blue"></i>
                          Tell us about it
                        </li>
                      </ul>
                    </div>

                    <hr />
                    <div class="space"></div>

                    <div class="center">
                      <a href="#" class="btn btn-grey">
                        <i class="icon-arrow-left"></i>
                        Go Back
                      </a>

                      <a href="#" class="btn btn-primary">
                        <i class="icon-dashboard"></i>
                        Dashboard
                      </a>
                    </div>
                  </div>
                </div>


@@ exception.html.ep
% layout 'error',
%   breadcrumbs => [
%     { text => 'Other Pages' },
%     { text => 'Error 500' },
%   ];
% title '500 Error Page';
<!-- 500 EXCEPTIONS -->
                <div class="error-container">
                  <div class="well">
                    <h1 class="grey lighter smaller">
                      <span class="blue bigger-125">
                        <i class="icon-random"></i>
                        500
                      </span>
                      <%= $exception->message %>
                    </h1>

                    <hr />
                    <h3 class="lighter smaller">
                      But we are working
                      <i class="icon-wrench icon-animated-wrench bigger-125"></i>
                      on it!
                    </h3>

                    <div class="space"></div>

                    <div>
                      <h4 class="lighter smaller">Meanwhile, try one of the following:</h4>

                      <ul class="list-unstyled spaced inline bigger-110 margin-15">
                        <li>
                          <i class="icon-hand-right blue"></i>
                          Read the faq
                        </li>

                        <li>
                          <i class="icon-hand-right blue"></i>
                          Give us more info on how this specific error occurred!
                        </li>
                      </ul>
                    </div>

                    <hr />
                    <div class="space"></div>

                    <div class="center">
                      <a href="#" class="btn btn-grey">
                        <i class="icon-arrow-left"></i>
                        Go Back
                      </a>

                      <a href="#" class="btn btn-primary">
                        <i class="icon-dashboard"></i>
                        Dashboard
                      </a>
                    </div>
                  </div>
                </div>


@@ layouts/login.html.haml
!!! 5
%html
  %head
    %title= title . ' - ' . $site->{name}
    = include 'layouts/default/meta'
    = include 'layouts/default/before-css'
    = include 'layouts/default/before-js'
    = include 'layouts/default/theme'
    = include 'layouts/default/css-page'
    = include 'layouts/default/after-css'
    = include 'layouts/default/after-js'

  %body.login-layout
    .main-container
      .main-content
        .row
          .col-sm-10.col-sm-offset-1
            .login-container
              .center
                %h1
                  != $site->{icon} ? qq[<i class="icon-$site->{icon} orange"></i>] : q{};
                  %span.white= $site->{name}
              .center
                %h1
                %h4.blue= "&copy; $company_name"
              .space-6
              .position-relative
                = include 'layouts/login/login-box'
                = include 'layouts/login/forgot-box'
                = include 'layouts/login/signup-box'
    = include 'layouts/default/body-js'
    = include 'layouts/default/body-js-theme'
    = include 'layouts/default/body-js-page'


@@ layouts/login/login-box.html.ep
<!-- LOGIN-BOX -->
                <div id="login-box" class="login-box visible widget-box no-border">
                  <div class="widget-body">
                    <div class="widget-main">
                      <h4 class="header blue lighter bigger">
                        <i class="icon-lock green"></i>
                        정보를 입력해주세요.
                      </h4>

                      <div class="space-6"></div>

                      <form>
                        <fieldset>
                          <label class="block clearfix">
                            <span class="block input-icon input-icon-right">
                              <input type="text" class="form-control" placeholder="사용자 이름" />
                              <i class="icon-user"></i>
                            </span>
                          </label>

                          <label class="block clearfix">
                            <span class="block input-icon input-icon-right">
                              <input type="password" class="form-control" placeholder="비밀번호" />
                              <i class="icon-key"></i>
                            </span>
                          </label>

                          <div class="space"></div>

                          <div class="clearfix">
                            <label class="inline">
                              <input type="checkbox" class="<%= $theme %>" />
                              <span class="lbl"> 기억하기</span>
                            </label>

                            <button type="button" class="width-35 pull-right btn btn-sm btn-primary">
                              <i class="icon-unlock"></i>
                              로그인
                            </button>
                          </div>

                          <div class="space-4"></div>
                        </fieldset>
                      </form>
                    </div><!-- /widget-main -->

                    <div class="toolbar clearfix">
                      <div>
                        <a href="#" onclick="show_box('forgot-box'); return false;" class="forgot-password-link">
                          <i class="icon-arrow-left"></i>
                          암호를 잊어버렸어요
                        </a>
                      </div>

                      <div>
                        <a href="#" onclick="show_box('signup-box'); return false;" class="user-signup-link">
                          가입할래요
                          <i class="icon-arrow-right"></i>
                        </a>
                      </div>
                    </div>
                  </div><!-- /widget-body -->
                </div><!-- /login-box -->


@@ layouts/login/forgot-box.html.ep
<!-- FORGOT-BOX -->
                <div id="forgot-box" class="forgot-box widget-box no-border">
                  <div class="widget-body">
                    <div class="widget-main">
                      <h4 class="header red lighter bigger">
                        <i class="icon-key"></i>
                        비밀번호를 초기화합니다.
                      </h4>

                      <div class="space-6"></div>
                      <p>
                        비밀번호를 새로 설정하는 방법을 이메일로 전달드립니다.
                        이메일 주소를 입력하세요.
                      </p>

                      <form>
                        <fieldset>
                          <label class="block clearfix">
                            <span class="block input-icon input-icon-right">
                              <input type="email" class="form-control" placeholder="이메일" />
                              <i class="icon-envelope"></i>
                            </span>
                          </label>

                          <div class="clearfix">
                            <button type="button" class="width-35 pull-right btn btn-sm btn-danger">
                              <i class="icon-lightbulb"></i>
                              보내주세요!
                            </button>
                          </div>
                        </fieldset>
                      </form>
                    </div><!-- /widget-main -->

                    <div class="toolbar center">
                      <a href="#" onclick="show_box('login-box'); return false;" class="back-to-login-link">
                        로그인 페이지로 돌아가기
                        <i class="icon-arrow-right"></i>
                      </a>
                    </div>
                  </div><!-- /widget-body -->
                </div><!-- /forgot-box -->


@@ layouts/error.html.haml
!!! 5
%html
  %head
    %title= title . ' - ' . $site->{name}
    = include 'layouts/default/meta'
    = include 'layouts/default/before-css'
    = include 'layouts/default/before-js'
    = include 'layouts/default/theme'
    = include 'layouts/default/after-css'
    = include 'layouts/default/after-js'

  %body
    = include 'layouts/default/navbar'
    #main-container.main-container
      .main-container-inner
        %a#menu-toggler.menu-toggler{:href = '#'}
          %span.menu-text
        = include 'layouts/default/sidebar'
        .main-content
          = include 'layouts/default/breadcrumbs'
          .page-content
            .row
              .col-xs-12
                / PAGE CONTENT BEGINS
                = content
                / PAGE CONTENT ENDS
    = include 'layouts/default/body-js'
    = include 'layouts/default/body-js-theme'


@@ layouts/login/signup-box.html.ep
<!-- SIGNUP-BOX -->
                <div id="signup-box" class="signup-box widget-box no-border">
                  <div class="widget-body">
                    <div class="widget-main">
                      <h4 class="header green lighter bigger">
                        <i class="icon-group blue"></i>
                        새로운 사용자 등록하기
                      </h4>

                      <div class="space-6"></div>
                      <p> 등록을 위해 다음 내용을 입력해주세요. </p>

                      <form>
                        <fieldset>
                          <label class="block clearfix">
                            <span class="block input-icon input-icon-right">
                              <input type="email" class="form-control" placeholder="이메일" />
                              <i class="icon-envelope"></i>
                            </span>
                          </label>

                          <label class="block clearfix">
                            <span class="block input-icon input-icon-right">
                              <input type="text" class="form-control" placeholder="사용자 이름" />
                              <i class="icon-user"></i>
                            </span>
                          </label>

                          <label class="block clearfix">
                            <span class="block input-icon input-icon-right">
                              <input type="password" class="form-control" placeholder="비밀번호" />
                              <i class="icon-lock"></i>
                            </span>
                          </label>

                          <label class="block clearfix">
                            <span class="block input-icon input-icon-right">
                              <input type="password" class="form-control" placeholder="비밀번호 확인" />
                              <i class="icon-retweet"></i>
                            </span>
                          </label>

                          <label class="block">
                            <input type="checkbox" class="<%= $theme %>" />
                            <span class="lbl">
                              <a href="#">사용자 약관</a>에 동의합니다.
                            </span>
                          </label>

                          <div class="space-24"></div>

                          <div class="clearfix">
                            <button type="reset" class="width-30 pull-left btn btn-sm">
                              <i class="icon-refresh"></i>
                              새로 쓰기
                            </button>

                            <button type="button" class="width-65 pull-right btn btn-sm btn-success">
                              등록하기
                              <i class="icon-arrow-right icon-on-right"></i>
                            </button>
                          </div>
                        </fieldset>
                      </form>
                    </div>

                    <div class="toolbar center">
                      <a href="#" onclick="show_box('login-box'); return false;" class="back-to-login-link">
                        <i class="icon-arrow-left"></i>
                        로그인 페이지로 돌아가기
                      </a>
                    </div>
                  </div><!-- /widget-body -->
                </div><!-- /signup-box -->
