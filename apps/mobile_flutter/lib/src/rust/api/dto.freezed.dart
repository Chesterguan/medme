// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'dto.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$TimelineGroupDto {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TimelineGroupDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'TimelineGroupDto()';
}


}

/// @nodoc
class $TimelineGroupDtoCopyWith<$Res>  {
$TimelineGroupDtoCopyWith(TimelineGroupDto _, $Res Function(TimelineGroupDto) __);
}


/// Adds pattern-matching-related methods to [TimelineGroupDto].
extension TimelineGroupDtoPatterns on TimelineGroupDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( TimelineGroupDto_Encounter value)?  encounter,TResult Function( TimelineGroupDto_Document value)?  document,required TResult orElse(),}){
final _that = this;
switch (_that) {
case TimelineGroupDto_Encounter() when encounter != null:
return encounter(_that);case TimelineGroupDto_Document() when document != null:
return document(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( TimelineGroupDto_Encounter value)  encounter,required TResult Function( TimelineGroupDto_Document value)  document,}){
final _that = this;
switch (_that) {
case TimelineGroupDto_Encounter():
return encounter(_that);case TimelineGroupDto_Document():
return document(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( TimelineGroupDto_Encounter value)?  encounter,TResult? Function( TimelineGroupDto_Document value)?  document,}){
final _that = this;
switch (_that) {
case TimelineGroupDto_Encounter() when encounter != null:
return encounter(_that);case TimelineGroupDto_Document() when document != null:
return document(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( EncounterSummaryDto encounter,  List<DocumentSummaryDto> docs)?  encounter,TResult Function( DocumentSummaryDto doc)?  document,required TResult orElse(),}) {final _that = this;
switch (_that) {
case TimelineGroupDto_Encounter() when encounter != null:
return encounter(_that.encounter,_that.docs);case TimelineGroupDto_Document() when document != null:
return document(_that.doc);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( EncounterSummaryDto encounter,  List<DocumentSummaryDto> docs)  encounter,required TResult Function( DocumentSummaryDto doc)  document,}) {final _that = this;
switch (_that) {
case TimelineGroupDto_Encounter():
return encounter(_that.encounter,_that.docs);case TimelineGroupDto_Document():
return document(_that.doc);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( EncounterSummaryDto encounter,  List<DocumentSummaryDto> docs)?  encounter,TResult? Function( DocumentSummaryDto doc)?  document,}) {final _that = this;
switch (_that) {
case TimelineGroupDto_Encounter() when encounter != null:
return encounter(_that.encounter,_that.docs);case TimelineGroupDto_Document() when document != null:
return document(_that.doc);case _:
  return null;

}
}

}

/// @nodoc


class TimelineGroupDto_Encounter extends TimelineGroupDto {
  const TimelineGroupDto_Encounter({required this.encounter, required final  List<DocumentSummaryDto> docs}): _docs = docs,super._();
  

 final  EncounterSummaryDto encounter;
 final  List<DocumentSummaryDto> _docs;
 List<DocumentSummaryDto> get docs {
  if (_docs is EqualUnmodifiableListView) return _docs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_docs);
}


/// Create a copy of TimelineGroupDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TimelineGroupDto_EncounterCopyWith<TimelineGroupDto_Encounter> get copyWith => _$TimelineGroupDto_EncounterCopyWithImpl<TimelineGroupDto_Encounter>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TimelineGroupDto_Encounter&&(identical(other.encounter, encounter) || other.encounter == encounter)&&const DeepCollectionEquality().equals(other._docs, _docs));
}


@override
int get hashCode => Object.hash(runtimeType,encounter,const DeepCollectionEquality().hash(_docs));

@override
String toString() {
  return 'TimelineGroupDto.encounter(encounter: $encounter, docs: $docs)';
}


}

/// @nodoc
abstract mixin class $TimelineGroupDto_EncounterCopyWith<$Res> implements $TimelineGroupDtoCopyWith<$Res> {
  factory $TimelineGroupDto_EncounterCopyWith(TimelineGroupDto_Encounter value, $Res Function(TimelineGroupDto_Encounter) _then) = _$TimelineGroupDto_EncounterCopyWithImpl;
@useResult
$Res call({
 EncounterSummaryDto encounter, List<DocumentSummaryDto> docs
});




}
/// @nodoc
class _$TimelineGroupDto_EncounterCopyWithImpl<$Res>
    implements $TimelineGroupDto_EncounterCopyWith<$Res> {
  _$TimelineGroupDto_EncounterCopyWithImpl(this._self, this._then);

  final TimelineGroupDto_Encounter _self;
  final $Res Function(TimelineGroupDto_Encounter) _then;

/// Create a copy of TimelineGroupDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? encounter = null,Object? docs = null,}) {
  return _then(TimelineGroupDto_Encounter(
encounter: null == encounter ? _self.encounter : encounter // ignore: cast_nullable_to_non_nullable
as EncounterSummaryDto,docs: null == docs ? _self._docs : docs // ignore: cast_nullable_to_non_nullable
as List<DocumentSummaryDto>,
  ));
}


}

/// @nodoc


class TimelineGroupDto_Document extends TimelineGroupDto {
  const TimelineGroupDto_Document({required this.doc}): super._();
  

 final  DocumentSummaryDto doc;

/// Create a copy of TimelineGroupDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TimelineGroupDto_DocumentCopyWith<TimelineGroupDto_Document> get copyWith => _$TimelineGroupDto_DocumentCopyWithImpl<TimelineGroupDto_Document>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TimelineGroupDto_Document&&(identical(other.doc, doc) || other.doc == doc));
}


@override
int get hashCode => Object.hash(runtimeType,doc);

@override
String toString() {
  return 'TimelineGroupDto.document(doc: $doc)';
}


}

/// @nodoc
abstract mixin class $TimelineGroupDto_DocumentCopyWith<$Res> implements $TimelineGroupDtoCopyWith<$Res> {
  factory $TimelineGroupDto_DocumentCopyWith(TimelineGroupDto_Document value, $Res Function(TimelineGroupDto_Document) _then) = _$TimelineGroupDto_DocumentCopyWithImpl;
@useResult
$Res call({
 DocumentSummaryDto doc
});




}
/// @nodoc
class _$TimelineGroupDto_DocumentCopyWithImpl<$Res>
    implements $TimelineGroupDto_DocumentCopyWith<$Res> {
  _$TimelineGroupDto_DocumentCopyWithImpl(this._self, this._then);

  final TimelineGroupDto_Document _self;
  final $Res Function(TimelineGroupDto_Document) _then;

/// Create a copy of TimelineGroupDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? doc = null,}) {
  return _then(TimelineGroupDto_Document(
doc: null == doc ? _self.doc : doc // ignore: cast_nullable_to_non_nullable
as DocumentSummaryDto,
  ));
}


}

// dart format on
